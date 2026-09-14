#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <errno.h>
#import <fcntl.h>
#import <net/if.h>
#import <os/log.h>
#import <sys/ioctl.h>
#import <sys/socket.h>
#import <unistd.h>
#import <xpc/xpc.h>

static const char *const kServiceName = "app.umbra.Umbra.awdl-helper";
static const char *const kExpectedClientIdentifier = "app.umbra.Umbra";
static const char *const kRecoveryMarker = "/var/run/app.umbra.Umbra.awdl-helper.restore";
static const char *const kOperationKey = "operation";
static const char *const kStatusKey = "status";
static const char *const kStateKey = "state";
static const char *const kMessageKey = "message";

typedef NS_ENUM(int64_t, UmbraAWDLState) {
  UmbraAWDLStateUp = 0,
  UmbraAWDLStateDown = 1,
  UmbraAWDLStateUnavailable = 2,
};

typedef NS_ENUM(int64_t, UmbraAWDLOperation) {
  UmbraAWDLOperationStatus = 1,
  UmbraAWDLOperationAcquire = 2,
  UmbraAWDLOperationRelease = 3,
};

static dispatch_queue_t gServiceQueue;
static NSMutableSet<NSValue *> *gLeaseConnections;
static SecRequirementRef gClientRequirement;
static BOOL gOriginalStateKnown;
static BOOL gOriginalStateWasUp;
static BOOL gRestoreRetryScheduled;
static BOOL gDisableReassertScheduled;
static BOOL gDisableReassertErrorLogged;

static NSString *UmbraErrnoMessage(NSString *operation) {
  return [NSString stringWithFormat:@"%@ failed: %s", operation, strerror(errno)];
}

static UmbraAWDLState UmbraReadAWDLState(NSString **errorMessage) {
  int descriptor = socket(AF_INET, SOCK_DGRAM, 0);
  if (descriptor < 0) {
    if (errorMessage != NULL) {
      *errorMessage = UmbraErrnoMessage(@"Opening the AWDL control socket");
    }
    return UmbraAWDLStateUnavailable;
  }
  struct ifreq request = {0};
  strlcpy(request.ifr_name, "awdl0", sizeof(request.ifr_name));
  if (ioctl(descriptor, SIOCGIFFLAGS, &request) != 0) {
    const int savedError = errno;
    close(descriptor);
    errno = savedError;
    if (errorMessage != NULL && savedError != ENXIO && savedError != ENODEV) {
      *errorMessage = UmbraErrnoMessage(@"Reading awdl0");
    }
    return UmbraAWDLStateUnavailable;
  }
  close(descriptor);
  return (request.ifr_flags & IFF_UP) != 0 ? UmbraAWDLStateUp : UmbraAWDLStateDown;
}

static BOOL UmbraSetAWDLEnabled(BOOL enabled, NSString **errorMessage) {
  int descriptor = socket(AF_INET, SOCK_DGRAM, 0);
  if (descriptor < 0) {
    if (errorMessage != NULL) {
      *errorMessage = UmbraErrnoMessage(@"Opening the AWDL control socket");
    }
    return NO;
  }
  struct ifreq request = {0};
  strlcpy(request.ifr_name, "awdl0", sizeof(request.ifr_name));
  if (ioctl(descriptor, SIOCGIFFLAGS, &request) != 0) {
    const int savedError = errno;
    close(descriptor);
    errno = savedError;
    if (errorMessage != NULL) {
      *errorMessage = UmbraErrnoMessage(@"Reading awdl0");
    }
    return NO;
  }
  if (enabled) {
    request.ifr_flags |= IFF_UP;
  } else {
    request.ifr_flags &= (short) ~IFF_UP;
  }
  if (ioctl(descriptor, SIOCSIFFLAGS, &request) != 0) {
    const int savedError = errno;
    close(descriptor);
    errno = savedError;
    if (errorMessage != NULL) {
      *errorMessage = UmbraErrnoMessage(enabled ? @"Enabling awdl0" : @"Disabling awdl0");
    }
    return NO;
  }
  close(descriptor);
  const UmbraAWDLState expected = enabled ? UmbraAWDLStateUp : UmbraAWDLStateDown;
  if (UmbraReadAWDLState(errorMessage) != expected) {
    if (errorMessage != NULL && *errorMessage == nil) {
      *errorMessage = @"macOS did not report the requested awdl0 state.";
    }
    return NO;
  }
  return YES;
}

static BOOL UmbraCreateRecoveryMarker(NSString **errorMessage) {
  int descriptor = open(kRecoveryMarker, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR);
  if (descriptor < 0) {
    if (errorMessage != NULL) {
      *errorMessage = UmbraErrnoMessage(@"Creating the AWDL recovery marker");
    }
    return NO;
  }
  const BOOL synced = fsync(descriptor) == 0;
  const int savedError = errno;
  close(descriptor);
  if (!synced) {
    unlink(kRecoveryMarker);
    errno = savedError;
    if (errorMessage != NULL) {
      *errorMessage = UmbraErrnoMessage(@"Saving the AWDL recovery marker");
    }
    return NO;
  }
  return YES;
}

static void UmbraRemoveRecoveryMarker(void) {
  if (unlink(kRecoveryMarker) != 0 && errno != ENOENT) {
    os_log_error(OS_LOG_DEFAULT, "Umbra AWDL helper could not remove recovery marker: %{public}s", strerror(errno));
  }
}

static BOOL UmbraRestoreOriginalState(NSString **errorMessage);

static void UmbraScheduleDisableReassertion(void) {
  if (gDisableReassertScheduled || gLeaseConnections.count == 0) {
    return;
  }
  gDisableReassertScheduled = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 250), gServiceQueue, ^{
    gDisableReassertScheduled = NO;
    if (gLeaseConnections.count == 0) {
      gDisableReassertErrorLogged = NO;
      return;
    }
    NSString *message = nil;
    const UmbraAWDLState state = UmbraReadAWDLState(&message);
    if (state == UmbraAWDLStateUp) {
      if (UmbraSetAWDLEnabled(NO, &message)) {
        os_log_info(OS_LOG_DEFAULT, "Umbra AWDL helper reasserted the active disable lease.");
        gDisableReassertErrorLogged = NO;
      } else if (!gDisableReassertErrorLogged) {
        os_log_error(OS_LOG_DEFAULT, "Umbra AWDL helper could not reassert awdl0: %{public}@", message);
        gDisableReassertErrorLogged = YES;
      }
    } else if (state == UmbraAWDLStateDown) {
      gDisableReassertErrorLogged = NO;
    } else if (!gDisableReassertErrorLogged) {
      os_log_error(OS_LOG_DEFAULT, "Umbra AWDL helper could not inspect awdl0: %{public}@", message);
      gDisableReassertErrorLogged = YES;
    }
    UmbraScheduleDisableReassertion();
  });
}

static void UmbraScheduleRestoreRetry(void) {
  if (gRestoreRetryScheduled || !gOriginalStateKnown || !gOriginalStateWasUp || gLeaseConnections.count != 0) {
    return;
  }
  gRestoreRetryScheduled = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), gServiceQueue, ^{
    gRestoreRetryScheduled = NO;
    NSString *message = nil;
    if (!UmbraRestoreOriginalState(&message)) {
      os_log_error(OS_LOG_DEFAULT, "Umbra AWDL helper restore retry failed: %{public}@", message);
      UmbraScheduleRestoreRetry();
    }
  });
}

static BOOL UmbraRestoreOriginalState(NSString **errorMessage) {
  if (!gOriginalStateKnown || gLeaseConnections.count != 0) {
    return YES;
  }
  if (gOriginalStateWasUp && !UmbraSetAWDLEnabled(YES, errorMessage)) {
    UmbraScheduleRestoreRetry();
    return NO;
  }
  if (gOriginalStateWasUp) {
    UmbraRemoveRecoveryMarker();
  }
  gOriginalStateKnown = NO;
  gOriginalStateWasUp = NO;
  return YES;
}

static BOOL UmbraAuthenticateMessage(xpc_object_t message) {
  SecCodeRef client = NULL;
  const OSStatus createStatus = SecCodeCreateWithXPCMessage(message, kSecCSDefaultFlags, &client);
  if (createStatus != errSecSuccess || client == NULL) {
    return NO;
  }
  const OSStatus validityStatus = SecCodeCheckValidity(client, kSecCSStrictValidate, gClientRequirement);
  CFRelease(client);
  return validityStatus == errSecSuccess;
}

static void UmbraReply(xpc_object_t message, int64_t status, UmbraAWDLState state, NSString *errorMessage) {
  xpc_object_t reply = xpc_dictionary_create_reply(message);
  if (reply == NULL) {
    return;
  }
  xpc_dictionary_set_int64(reply, kStatusKey, status);
  xpc_dictionary_set_int64(reply, kStateKey, state);
  if (errorMessage.length != 0) {
    xpc_dictionary_set_string(reply, kMessageKey, errorMessage.UTF8String);
  }
  xpc_connection_t remote = xpc_dictionary_get_remote_connection(message);
  if (remote != NULL) {
    xpc_connection_send_message(remote, reply);
  }
}

static void UmbraReleaseLease(NSValue *connectionKey) {
  if (![gLeaseConnections containsObject:connectionKey]) {
    return;
  }
  [gLeaseConnections removeObject:connectionKey];
  NSString *message = nil;
  if (!UmbraRestoreOriginalState(&message)) {
    os_log_error(OS_LOG_DEFAULT, "Umbra AWDL helper could not restore awdl0: %{public}@", message);
  }
}

static void UmbraHandleMessage(NSValue *connectionKey, xpc_object_t message) {
  if (!UmbraAuthenticateMessage(message)) {
    UmbraReply(message, EPERM, UmbraAWDLStateUnavailable, @"The XPC caller is not an authenticated Umbra app.");
    return;
  }
  const int64_t operation = xpc_dictionary_get_int64(message, kOperationKey);
  NSString *errorMessage = nil;
  if (operation == UmbraAWDLOperationStatus) {
    UmbraAWDLState state = UmbraReadAWDLState(&errorMessage);
    UmbraReply(message, errorMessage == nil ? 0 : EIO, state, errorMessage);
    return;
  }
  if (operation == UmbraAWDLOperationAcquire) {
    if ([gLeaseConnections containsObject:connectionKey]) {
      UmbraAWDLState state = UmbraReadAWDLState(&errorMessage);
      if (state == UmbraAWDLStateUnavailable) {
        UmbraReply(message, ENODEV, state, errorMessage ?: @"awdl0 is unavailable.");
        return;
      }
      if (state == UmbraAWDLStateUp && !UmbraSetAWDLEnabled(NO, &errorMessage)) {
        UmbraReply(message, EIO, state, errorMessage);
        return;
      }
      UmbraScheduleDisableReassertion();
      UmbraReply(message, errorMessage == nil ? 0 : EIO, UmbraAWDLStateDown, errorMessage);
      return;
    }
    UmbraAWDLState state = UmbraReadAWDLState(&errorMessage);
    if (errorMessage != nil || state == UmbraAWDLStateUnavailable) {
      UmbraReply(message, ENODEV, state, errorMessage ?: @"awdl0 is unavailable.");
      return;
    }
    if (!gOriginalStateKnown) {
      gOriginalStateKnown = YES;
      gOriginalStateWasUp = state == UmbraAWDLStateUp;
      if (gOriginalStateWasUp && !UmbraCreateRecoveryMarker(&errorMessage)) {
        gOriginalStateKnown = NO;
        gOriginalStateWasUp = NO;
        UmbraReply(message, EIO, state, errorMessage);
        return;
      }
    }
    if (state == UmbraAWDLStateUp && !UmbraSetAWDLEnabled(NO, &errorMessage)) {
      if (gLeaseConnections.count == 0) {
        UmbraRemoveRecoveryMarker();
        gOriginalStateKnown = NO;
        gOriginalStateWasUp = NO;
      }
      UmbraReply(message, EIO, state, errorMessage);
      return;
    }
    [gLeaseConnections addObject:connectionKey];
    UmbraScheduleDisableReassertion();
    UmbraReply(message, 0, UmbraAWDLStateDown, nil);
    return;
  }
  if (operation == UmbraAWDLOperationRelease) {
    UmbraReleaseLease(connectionKey);
    UmbraAWDLState state = UmbraReadAWDLState(&errorMessage);
    UmbraReply(message, errorMessage == nil ? 0 : EIO, state, errorMessage);
    return;
  }
  UmbraReply(message, EINVAL, UmbraAWDLStateUnavailable, @"Unsupported AWDL helper operation.");
}

static SecRequirementRef UmbraCreateClientRequirement(void) {
  SecCodeRef ownCode = NULL;
  CFDictionaryRef signingInformation = NULL;
  SecRequirementRef requirement = NULL;
  if (SecCodeCopySelf(kSecCSDefaultFlags, &ownCode) != errSecSuccess || ownCode == NULL) {
    return NULL;
  }
  if (SecCodeCopySigningInformation(ownCode, kSecCSSigningInformation, &signingInformation) != errSecSuccess ||
      signingInformation == NULL) {
    CFRelease(ownCode);
    return NULL;
  }
  NSString *teamIdentifier = (__bridge NSString *) CFDictionaryGetValue(signingInformation, kSecCodeInfoTeamIdentifier);
  NSCharacterSet *invalidCharacters = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
  if (teamIdentifier.length == 0 || [teamIdentifier rangeOfCharacterFromSet:invalidCharacters].location != NSNotFound) {
    CFRelease(signingInformation);
    CFRelease(ownCode);
    return NULL;
  }
  NSString *requirementText = [NSString stringWithFormat:
      @"anchor apple generic and identifier \"%s\" and certificate leaf[subject.OU] = \"%@\"",
      kExpectedClientIdentifier,
      teamIdentifier];
  SecRequirementCreateWithString((__bridge CFStringRef) requirementText, kSecCSDefaultFlags, &requirement);
  CFRelease(signingInformation);
  CFRelease(ownCode);
  return requirement;
}

int main(void) {
  @autoreleasepool {
    gServiceQueue = dispatch_queue_create("app.umbra.Umbra.awdl-helper", DISPATCH_QUEUE_SERIAL);
    gLeaseConnections = [NSMutableSet set];
    gClientRequirement = UmbraCreateClientRequirement();
    if (gClientRequirement == NULL) {
      os_log_error(OS_LOG_DEFAULT, "Umbra AWDL helper could not construct its client requirement.");
      return EXIT_FAILURE;
    }

    if (access(kRecoveryMarker, F_OK) == 0) {
      NSString *message = nil;
      if (!UmbraSetAWDLEnabled(YES, &message)) {
        os_log_error(OS_LOG_DEFAULT, "Umbra AWDL helper startup recovery failed: %{public}@", message);
        return EXIT_FAILURE;
      }
      UmbraRemoveRecoveryMarker();
    }

    xpc_connection_t listener = xpc_connection_create_mach_service(
        kServiceName,
        gServiceQueue,
        XPC_CONNECTION_MACH_SERVICE_LISTENER);
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peerObject) {
      if (xpc_get_type(peerObject) != XPC_TYPE_CONNECTION) {
        return;
      }
      xpc_connection_t peer = (xpc_connection_t) peerObject;
      NSValue *connectionKey = [NSValue valueWithPointer:(__bridge const void *) peer];
      xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_DICTIONARY) {
          UmbraHandleMessage(connectionKey, event);
        } else if (event == XPC_ERROR_CONNECTION_INVALID || event == XPC_ERROR_CONNECTION_INTERRUPTED) {
          UmbraReleaseLease(connectionKey);
        }
      });
      xpc_connection_activate(peer);
    });
    xpc_connection_activate(listener);
    dispatch_main();
  }
}
