import CoreGraphics
import CoreAudio
import CoreMedia
import CoreVideo
import XCTest
@testable import UmbraMedia

final class MediaFormatTests: XCTestCase {
    func testAV1ConfigurationUsesParsedDepthSubsamplingAndRejectsColorMismatch() throws {
        let profile = try VideoCodecProfile(codecMask: MoonlightVideoFormat.av1Main10.rawValue)
        let sequence = Data([
            0x12, 0x00, 0x0a, 0x0a, 0x00, 0x00, 0x00,
            0x02, 0xaf, 0xff, 0x89, 0x5f, 0x28, 0x08,
        ])
        let parsed = try AV1AccessUnit(data: sequence, profile: profile)
        XCTAssertEqual(parsed.codecConfigurationRecord[0], 0x81)
        XCTAssertNotEqual(parsed.codecConfigurationRecord[2] & 0x40, 0)
        XCTAssertNotEqual(parsed.codecConfigurationRecord[2] & 0x0c, 0)

        let exactFormat = VideoStreamFormat(
            codecMask: MoonlightVideoFormat.av1Main10.rawValue,
            width: 64,
            height: 64,
            redrawRate: 60,
            colorRange: .video,
            requiresExactDecodedFormat: true,
            colorPrimariesCode: 1,
            transferCharacteristicsCode: 1,
            matrixCoefficientsCode: 1
        )
        XCTAssertThrowsError(try AV1AccessUnit(
            data: sequence,
            profile: profile,
            expectedColor: try XCTUnwrap(AV1ExpectedColor(format: exactFormat))
        ))
    }

    func testMoonlightCodecMasksMapToCodecDepthAndChroma() throws {
        XCTAssertEqual(try VideoCodecProfile(codecMask: 0x0001).codec, .h264)
        XCTAssertFalse(try VideoCodecProfile(codecMask: 0x0001).isTenBit)
        XCTAssertTrue(try VideoCodecProfile(codecMask: 0x0004).isYUV444)

        let hevcMain10 = try VideoCodecProfile(codecMask: 0x0200)
        XCTAssertEqual(hevcMain10.codec, .hevc)
        XCTAssertTrue(hevcMain10.isTenBit)
        XCTAssertFalse(hevcMain10.isYUV444)

        let av1High10 = try VideoCodecProfile(codecMask: 0x8000)
        XCTAssertEqual(av1High10.codec, .av1)
        XCTAssertTrue(av1High10.isTenBit)
        XCTAssertTrue(av1High10.isYUV444)
        XCTAssertThrowsError(try VideoCodecProfile(codecMask: 0))
        XCTAssertThrowsError(try VideoCodecProfile(codecMask: 0x0101))
        XCTAssertThrowsError(try VideoCodecProfile(codecMask: 0x0300))
        XCTAssertThrowsError(try VideoCodecProfile(codecMask: 0x0020))
    }

    func testCapabilityMaskOnlyAdvertisesProbeableProfiles() {
        let capabilities = AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 8
        )
        XCTAssertEqual(capabilities.supportedVideoFormatMask, 0x1101)
        XCTAssertEqual(capabilities.supportedVideoFormatMask & VideoCodecProfile.yuv444Mask, 0)

        let profileProven = AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 8,
            supportsHardwareHEVCMain10: true,
            supportsHardwareAV1Main10: true,
            supportedHardwareYUV444FormatMask: VideoCodecProfile.yuv444Mask
        )
        XCTAssertEqual(profileProven.supportedVideoFormatMask, 0xFF05)

        let headless = AppleStreamingCapabilities(
            hasMetalDevice: false,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: false,
            supportsNativeAudioOutput: false,
            audioOutputChannelCount: 0
        )
        XCTAssertEqual(headless.supportedVideoFormatMask, 0x1101)
    }

    func testVideoGeometryAspectFitAndFill() {
        let source = CGSize(width: 1920, height: 1080)
        let destination = CGSize(width: 1000, height: 1000)

        let fit = VideoGeometry.quad(source: source, destination: destination, mode: .aspectFit)
        XCTAssertEqual(fit.clipScale.x, 1, accuracy: 0.0001)
        XCTAssertEqual(fit.clipScale.y, 0.5625, accuracy: 0.0001)
        XCTAssertEqual(fit.textureRect, CGRect(x: 0, y: 0, width: 1, height: 1))

        let fill = VideoGeometry.quad(source: source, destination: destination, mode: .aspectFill)
        XCTAssertEqual(fill.clipScale, CGPoint(x: 1, y: 1))
        XCTAssertEqual(fill.textureRect.width, 0.5625, accuracy: 0.0001)
        XCTAssertEqual(fill.textureRect.midX, 0.5, accuracy: 0.0001)
    }

    func testYUVConversionUsesRangeAndColorSpace() {
        let limited = YUVConversion(metadata: .rec709SDR)
        XCTAssertEqual(limited.offset[0], -16.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(limited.offset[1], -0.5, accuracy: 0.0001)
        XCTAssertEqual(limited.matrix[0], 255.0 / 219.0, accuracy: 0.0001)
        XCTAssertEqual(limited.matrix[2], 1.7927, accuracy: 0.002)

        let full2020 = YUVConversion(
            metadata: VideoColorMetadata(
                colorSpace: .rec2020,
                range: .full,
                transferFunction: .pq
            )
        )
        XCTAssertEqual(full2020.offset[0], 0, accuracy: 0.0001)
        XCTAssertEqual(full2020.matrix[0], 1, accuracy: 0.0001)
        XCTAssertEqual(full2020.matrix[2], 1.4746, accuracy: 0.0001)
    }

    func testDecodedBitstreamColorAttachmentsOverrideAsynchronousSDRHint() throws {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        ), kCVReturnSuccess)
        let imageBuffer = try XCTUnwrap(pixelBuffer)
        let mastering = Data(repeating: 0x2A, count: 24)
        let content = Data([0x03, 0xE8, 0x01, 0x90])
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferMasteringDisplayColorVolumeKey,
            mastering as NSData,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferContentLightLevelInfoKey,
            content as NSData,
            .shouldPropagate
        )

        let resolved = resolvedColorMetadata(
            fallback: .rec709SDR,
            imageBuffer: imageBuffer
        )

        XCTAssertEqual(resolved.colorSpace, .rec2020)
        XCTAssertEqual(resolved.range, .full)
        XCTAssertEqual(resolved.transferFunction, .pq)
        XCTAssertEqual(resolved.hdrStaticMetadata?.masteringDisplayColorVolume, mastering)
        XCTAssertEqual(resolved.hdrStaticMetadata?.contentLightLevelInfo, content)
    }

    func testRec2020PQAttachmentReplacesOnlyAConflictingCGColorSpace() throws {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        ), kCVReturnSuccess)
        let imageBuffer = try XCTUnwrap(pixelBuffer)
        let mastering = Data(repeating: 0x2A, count: 24)
        let content = Data([0x03, 0xE8, 0x01, 0x90])
        let conflictingColorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferMasteringDisplayColorVolumeKey,
            mastering as NSData,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferContentLightLevelInfoKey,
            content as NSData,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferCGColorSpaceKey,
            conflictingColorSpace,
            .shouldPropagate
        )

        applyColorAttachments(
            VideoColorMetadata(
                colorSpace: .rec2020,
                range: .full,
                transferFunction: .pq,
                hdrStaticMetadata: HDRStaticMetadata(
                    masteringDisplayColorVolume: mastering,
                    contentLightLevelInfo: content
                )
            ),
            to: imageBuffer,
            overwriteExisting: false
        )

        let attachedColorSpace = try XCTUnwrap(
            CVBufferCopyAttachment(imageBuffer, kCVImageBufferCGColorSpaceKey, nil)
        )
        let expectedColorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.itur_2100_PQ))
        XCTAssertTrue(CFEqual(attachedColorSpace, expectedColorSpace))
        XCTAssertTrue(CFEqual(
            try XCTUnwrap(CVBufferCopyAttachment(imageBuffer, kCVImageBufferColorPrimariesKey, nil)),
            kCVImageBufferColorPrimaries_ITU_R_2020
        ))
        XCTAssertTrue(CFEqual(
            try XCTUnwrap(CVBufferCopyAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey, nil)),
            kCVImageBufferYCbCrMatrix_ITU_R_2020
        ))
        XCTAssertTrue(CFEqual(
            try XCTUnwrap(CVBufferCopyAttachment(imageBuffer, kCVImageBufferTransferFunctionKey, nil)),
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        ))
        XCTAssertEqual(
            CVBufferCopyAttachment(imageBuffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data,
            mastering
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(imageBuffer, kCVImageBufferContentLightLevelInfoKey, nil) as? Data,
            content
        )
    }

    func testAudioConfigurationsRoundTrip() {
        for layout in AudioOutputLayout.allCases {
            XCTAssertEqual(AudioOutputLayout(audioConfiguration: layout.audioConfiguration), layout)
            XCTAssertEqual(layout.channelCount, UInt32((layout.audioConfiguration >> 8) & 0xFF))
        }
        XCTAssertEqual(AudioOutputLayout.surround51.coreAudioLayoutTag, kAudioChannelLayoutTag_MPEG_5_1_A)
        XCTAssertEqual(AudioOutputLayout.surround71.coreAudioLayoutTag, kAudioChannelLayoutTag_WAVE_7_1)
        XCTAssertNil(AudioOutputLayout(audioConfiguration: 0))
    }

    func testInactiveMuteStateCombinesPolicyAndManualMute() {
        var mute = InactiveMuteState(muteWhileInactive: true)
        XCTAssertFalse(mute.isMuted)
        mute.setApplicationActive(false)
        XCTAssertTrue(mute.isMuted)
        mute.muteWhileInactive = false
        XCTAssertFalse(mute.isMuted)
        mute.manuallyMuted = true
        XCTAssertTrue(mute.isMuted)
    }

    func testAnnexBConversionOwnsUnitsAndWritesBigEndianLengths() throws {
        let accessUnit = Data([
            0, 0, 0, 1, 0x67, 0x64, 0x1F,
            0, 0, 1, 0x68, 0xEE,
            0, 0, 0, 1, 0x65, 0xAA, 0xBB,
        ])
        let converted = try AnnexBAccessUnit(data: accessUnit, codec: .h264)
        XCTAssertEqual(converted.unitCount, 3)
        XCTAssertEqual(converted.parameterSets, [Data([0x67, 0x64, 0x1F]), Data([0x68, 0xEE])])
        XCTAssertEqual(
            converted.lengthPrefixedData,
            Data([
                0, 0, 0, 3, 0x67, 0x64, 0x1F,
                0, 0, 0, 2, 0x68, 0xEE,
                0, 0, 0, 3, 0x65, 0xAA, 0xBB,
            ])
        )
        XCTAssertThrowsError(try AnnexBAccessUnit(data: Data([0x65, 0x01]), codec: .h264))
    }

    func testAnnexBConversionWritesDirectlyIntoCoreMediaOwnedStorage() throws {
        let accessUnit = Data([
            0, 0, 1, 0x67, 0x64, 0x1F,
            0, 0, 0, 1, 0x68, 0xEE,
            0, 0, 1, 0x65, 0xAA, 0xBB,
        ])
        let converted = try AnnexBAccessUnit(data: accessUnit, codec: .h264)
        let blockBuffer = try converted.lengthPrefixedPayload.makeBlockBuffer()
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        XCTAssertEqual(CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ), noErr)
        XCTAssertEqual(totalLength, converted.lengthPrefixedPayload.count)
        XCTAssertEqual(lengthAtOffset, converted.lengthPrefixedPayload.count)
        XCTAssertEqual(
            dataPointer.map { UInt(bitPattern: $0) },
            UInt(bitPattern: converted.lengthPrefixedPayload.baseAddress),
            "CoreMedia must reference the final converted allocation instead of copying it."
        )
    }

    func testLengthPrefixedAccessUnitValidatesAndRetainsFinalStorage() throws {
        let byteCount = 7 + 6 + 7
        let allocation = try XCTUnwrap(malloc(byteCount))
        let bytes: [UInt8] = [
            0, 0, 0, 3, 0x67, 0x64, 0x1F,
            0, 0, 0, 2, 0x68, 0xEE,
            0, 0, 0, 3, 0x65, 0xAA, 0xBB,
        ]
        bytes.withUnsafeBytes { source in
            allocation.copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
        let sourceAddress = UInt(bitPattern: allocation)
        let data = Data(bytesNoCopy: allocation, count: bytes.count, deallocator: .free)

        let accessUnit = try LengthPrefixedAccessUnit(data: data, codec: .h264)
        XCTAssertEqual(accessUnit.unitCount, 3)
        XCTAssertEqual(accessUnit.parameterSets, [Data([0x67, 0x64, 0x1F]), Data([0x68, 0xEE])])
        XCTAssertEqual(UInt(bitPattern: accessUnit.payload.baseAddress), sourceAddress)
        let blockBuffer = try accessUnit.payload.makeBlockBuffer()
        var contiguousLength = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        XCTAssertEqual(CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &contiguousLength,
            totalLengthOut: &totalLength,
            dataPointerOut: &pointer
        ), noErr)
        XCTAssertEqual(pointer.map(UInt.init(bitPattern:)), sourceAddress)
        XCTAssertEqual(totalLength, bytes.count)
    }

    func testLengthPrefixedAccessUnitRejectsZeroTruncatedAndTrailingUnits() {
        XCTAssertThrowsError(try LengthPrefixedAccessUnit(
            data: Data([0, 0, 0, 0]),
            codec: .h264
        ))
        XCTAssertThrowsError(try LengthPrefixedAccessUnit(
            data: Data([0, 0, 0, 3, 0x67, 0x64]),
            codec: .h264
        ))
        XCTAssertThrowsError(try LengthPrefixedAccessUnit(
            data: Data([0, 0, 0, 1, 0x67, 0xAA]),
            codec: .h264
        ))
    }

    func testLengthPrefixedHEVCExtractsOnlyFixedParameterSets() throws {
        let data = Data([
            0, 0, 0, 3, 0x40, 0x01, 0xAA,
            0, 0, 0, 4, 0x42, 0x01, 0xBB, 0xCC,
            0, 0, 0, 3, 0x44, 0x01, 0xDD,
            0, 0, 0, 3, 0x26, 0x01, 0xEE,
        ])
        let accessUnit = try LengthPrefixedAccessUnit(data: data, codec: .hevc)
        XCTAssertEqual(accessUnit.unitCount, 4)
        XCTAssertEqual(accessUnit.parameterSets, [
            Data([0x40, 0x01, 0xAA]),
            Data([0x42, 0x01, 0xBB, 0xCC]),
            Data([0x44, 0x01, 0xDD]),
        ])
    }

    func testHEVCAnnexBConversionPreservesVPSPPSAndPictureBytesExactly() throws {
        let accessUnit = Data([
            0, 0, 1, 0x40, 0x01, 0xAA,
            0, 0, 0, 1, 0x42, 0x01, 0xBB, 0xCC,
            0, 0, 1, 0x44, 0x01, 0xDD,
            0, 0, 0, 1, 0x26, 0x01, 0xEE, 0xFF,
        ])
        let converted = try AnnexBAccessUnit(data: accessUnit, codec: .hevc)

        XCTAssertEqual(converted.parameterSets, [
            Data([0x40, 0x01, 0xAA]),
            Data([0x42, 0x01, 0xBB, 0xCC]),
            Data([0x44, 0x01, 0xDD]),
        ])
        XCTAssertEqual(converted.lengthPrefixedData, Data([
            0, 0, 0, 3, 0x40, 0x01, 0xAA,
            0, 0, 0, 4, 0x42, 0x01, 0xBB, 0xCC,
            0, 0, 0, 3, 0x44, 0x01, 0xDD,
            0, 0, 0, 4, 0x26, 0x01, 0xEE, 0xFF,
        ]))
    }

    func testParameterSetExtractionUsesSliceRelativeByteOffsets() throws {
        let annexBBytes = Data([
            0, 0, 1, 0x40, 0x01, 0xAA,
            0, 0, 1, 0x42, 0x01, 0xBB,
            0, 0, 1, 0x44, 0x01, 0xCC,
            0, 0, 1, 0x26, 0x01, 0xDD,
        ])
        let annexBStorage = Data([0xFE, 0xED]) + annexBBytes + Data([0xEF])
        let annexBSlice = annexBStorage.dropFirst(2).dropLast()
        XCTAssertNotEqual(annexBSlice.startIndex, 0)

        let annexB = try AnnexBAccessUnit(data: annexBSlice, codec: .hevc)
        XCTAssertEqual(annexB.parameterSets, [
            Data([0x40, 0x01, 0xAA]),
            Data([0x42, 0x01, 0xBB]),
            Data([0x44, 0x01, 0xCC]),
        ])

        let lengthPrefixedBytes = Data([
            0, 0, 0, 3, 0x67, 0x64, 0x1F,
            0, 0, 0, 2, 0x68, 0xEE,
            0, 0, 0, 2, 0x65, 0xAA,
        ])
        let lengthPrefixedStorage = Data([0xFA]) + lengthPrefixedBytes + Data([0xFB])
        let lengthPrefixedSlice = lengthPrefixedStorage.dropFirst().dropLast()
        XCTAssertNotEqual(lengthPrefixedSlice.startIndex, 0)

        let lengthPrefixed = try LengthPrefixedAccessUnit(
            data: lengthPrefixedSlice,
            codec: .h264
        )
        XCTAssertEqual(lengthPrefixed.parameterSets, [
            Data([0x67, 0x64, 0x1F]),
            Data([0x68, 0xEE]),
        ])
    }

    func testRecoveryKeyFrameReusesRetainedParameterSets() {
        let retained = [Data([0x40, 0x01]), Data([0x42, 0x01]), Data([0x44, 0x01])]
        XCTAssertEqual(
            VideoToolboxDecoder.parameterSetsForSessionRecreation(
                inline: [],
                retained: retained,
                isKeyFrame: true,
                hasSession: true,
                requiresRecovery: true
            ),
            retained
        )
        XCTAssertNil(VideoToolboxDecoder.parameterSetsForSessionRecreation(
            inline: [],
            retained: retained,
            isKeyFrame: false,
            hasSession: true,
            requiresRecovery: true
        ))
        XCTAssertNil(VideoToolboxDecoder.parameterSetsForSessionRecreation(
            inline: retained,
            retained: retained,
            isKeyFrame: true,
            hasSession: true,
            requiresRecovery: false
        ))
    }

    func testAV1LowOverheadOBUBytesRemainByteIdenticalInCoreMediaStorage() throws {
        let accessUnit = Data([
            0x12, 0x00,
            0x0A, 0x10, 0x00, 0x00, 0x00, 0x43, 0xFC, 0x13,
            0xFC, 0x0B, 0x3C, 0x02, 0x4E, 0x88, 0x30, 0x30, 0x30, 0xA0,
            0x32, 0x03, 0xDE, 0xAD, 0xBE,
        ])
        let payload = try EncodedVideoPayload(retaining: accessUnit)

        XCTAssertEqual(payload.copiedData(), accessUnit)
        let blockBuffer = try payload.makeBlockBuffer()
        var copied = Data(count: accessUnit.count)
        let status = copied.withUnsafeMutableBytes { destination in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: destination.count,
                destination: destination.baseAddress!
            )
        }
        XCTAssertEqual(status, noErr)
        XCTAssertEqual(copied, accessUnit)
    }

    func testCoreMediaBlockRetainsAdoptedAV1BytesUntilFinalRelease() throws {
        let releases = MediaFormatLockedCounter()
        var blockBuffer: CMBlockBuffer?
        weak var weakPayload: EncodedVideoPayload?
        do {
            let payload = try EncodedVideoPayload(
                retaining: Data([0x12, 0x00, 0x32, 0x01, 0xFF]),
                releaseObserver: { releases.increment() }
            )
            weakPayload = payload
            blockBuffer = try payload.makeBlockBuffer()
        }

        XCTAssertNotNil(weakPayload)
        XCTAssertEqual(releases.value, 0)
        XCTAssertEqual(CMBlockBufferGetDataLength(try XCTUnwrap(blockBuffer)), 5)
        blockBuffer = nil
        XCTAssertNil(weakPayload)
        XCTAssertEqual(releases.value, 1)
    }

    func testMallocBackedAV1DataRemainsPointerIdenticalThroughCoreMediaLifetime() throws {
        let releases = MediaFormatLockedCounter()
        try autoreleasepool {
            let byteCount = 4_096
            let allocation = try XCTUnwrap(malloc(byteCount))
            memset(allocation, 0x5A, byteCount)
            let sourceAddress = UInt(bitPattern: allocation)
            var source: Data? = Data(
                bytesNoCopy: allocation,
                count: byteCount,
                deallocator: .custom { pointer, _ in
                    free(pointer)
                    releases.increment()
                }
            )
            var payload: EncodedVideoPayload? = try EncodedVideoPayload(retaining: try XCTUnwrap(source))
            XCTAssertEqual(payload.map { UInt(bitPattern: $0.baseAddress) }, sourceAddress)
            var blockBuffer: CMBlockBuffer? = try payload?.makeBlockBuffer()
            source = nil
            payload = nil
            XCTAssertEqual(releases.value, 0)

            var blockDataPointer: UnsafeMutablePointer<Int8>?
            XCTAssertEqual(CMBlockBufferGetDataPointer(
                try XCTUnwrap(blockBuffer),
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: nil,
                dataPointerOut: &blockDataPointer
            ), noErr)
            XCTAssertEqual(blockDataPointer.map { UInt(bitPattern: $0) }, sourceAddress)
            blockBuffer = nil
        }
        XCTAssertEqual(releases.value, 1)
    }

    func testCoreMediaBlockStorageDeallocatesExactlyOnceUnderConcurrency() {
        let releases = MediaFormatLockedCounter()
        let failures = MediaFormatLockedCounter()

        DispatchQueue.concurrentPerform(iterations: 256) { iteration in
            autoreleasepool {
                do {
                    let payload = try EncodedVideoPayload(
                        retaining: Data(repeating: UInt8(truncatingIfNeeded: iteration), count: 64),
                        releaseObserver: { releases.increment() }
                    )
                    let blockBuffer = try payload.makeBlockBuffer()
                    guard CMBlockBufferGetDataLength(blockBuffer) == 64 else {
                        failures.increment()
                        return
                    }
                } catch {
                    failures.increment()
                }
            }
        }

        XCTAssertEqual(failures.value, 0)
        XCTAssertEqual(releases.value, 256)
    }

    func testEncodedStorageAllocationFailureAndFrameBoundsFailClosed() {
        let allocationCalls = MediaFormatLockedCounter()
        XCTAssertThrowsError(try AnnexBAccessUnit(
            data: Data([0, 0, 0, 1, 0x65, 0xAA]),
            codec: .h264,
            allocator: { _ in
                allocationCalls.increment()
                return nil
            }
        )) { error in
            XCTAssertEqual(error as? VideoDecoderError, .encodedStorageAllocationFailed)
        }
        XCTAssertEqual(allocationCalls.value, 1)
        XCTAssertFalse(EncodedVideoPayload.isValidByteCount(0))
        XCTAssertTrue(EncodedVideoPayload.isValidByteCount(EncodedVideoPayload.maximumByteCount))
        XCTAssertFalse(EncodedVideoPayload.isValidByteCount(EncodedVideoPayload.maximumByteCount + 1))
    }

    func testAnnexBValidationRejectsBeforeCallingAllocator() {
        let allocationCalls = MediaFormatLockedCounter()
        XCTAssertThrowsError(try AnnexBAccessUnit(
            data: Data([0, 0, 1, 0, 0, 1, 0x65]),
            codec: .h264,
            allocator: { byteCount in
                allocationCalls.increment()
                return malloc(byteCount)
            }
        )) { error in
            XCTAssertEqual(error as? VideoDecoderError, .invalidAccessUnit)
        }
        XCTAssertEqual(allocationCalls.value, 0)
    }

    func testAnnexBExactOutputCapAllocatesOnceAndCapPlusOneRejectsBeforeAllocation() throws {
        let maximumByteCount = EncodedVideoPayload.maximumByteCount
        let exactAllocationCalls = MediaFormatLockedCounter()
        try autoreleasepool {
            var exactCap = Data(repeating: 0xFF, count: maximumByteCount)
            exactCap.replaceSubrange(0..<4, with: [0, 0, 0, 1])
            let converted = try AnnexBAccessUnit(
                data: exactCap,
                codec: .h264,
                allocator: { byteCount in
                    exactAllocationCalls.increment()
                    return malloc(byteCount)
                }
            )
            XCTAssertEqual(converted.lengthPrefixedPayload.count, maximumByteCount)
        }
        XCTAssertEqual(exactAllocationCalls.value, 1)

        let overflowAllocationCalls = MediaFormatLockedCounter()
        try autoreleasepool {
            var capPlusOne = Data(repeating: 0xFF, count: maximumByteCount)
            capPlusOne.replaceSubrange(0..<3, with: [0, 0, 1])
            XCTAssertThrowsError(try AnnexBAccessUnit(
                data: capPlusOne,
                codec: .h264,
                allocator: { byteCount in
                    overflowAllocationCalls.increment()
                    return malloc(byteCount)
                }
            )) { error in
                XCTAssertEqual(error as? VideoDecoderError, .invalidAccessUnit)
            }
        }
        XCTAssertEqual(overflowAllocationCalls.value, 0)
    }

    func testConvertedAnnexBStorageKeepsPointerIdentityAndReleasesExactlyOnce() throws {
        let allocationCalls = MediaFormatLockedCounter()
        let releases = MediaFormatLockedCounter()
        var blockBuffer: CMBlockBuffer?
        weak var weakPayload: EncodedVideoPayload?

        do {
            var converted: AnnexBAccessUnit? = try AnnexBAccessUnit(
                data: Data([0, 0, 1, 0x65, 0xAA, 0xBB]),
                codec: .h264,
                allocator: { byteCount in
                    allocationCalls.increment()
                    return malloc(byteCount)
                },
                releaseObserver: { releases.increment() }
            )
            let payload = try XCTUnwrap(converted?.lengthPrefixedPayload)
            weakPayload = payload
            blockBuffer = try payload.makeBlockBuffer()
            var blockDataPointer: UnsafeMutablePointer<Int8>?
            XCTAssertEqual(CMBlockBufferGetDataPointer(
                try XCTUnwrap(blockBuffer),
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: nil,
                dataPointerOut: &blockDataPointer
            ), noErr)
            XCTAssertEqual(
                blockDataPointer.map { UInt(bitPattern: $0) },
                UInt(bitPattern: payload.baseAddress)
            )
            converted = nil
        }

        XCTAssertEqual(allocationCalls.value, 1)
        XCTAssertNotNil(weakPayload)
        XCTAssertEqual(releases.value, 0)
        blockBuffer = nil
        XCTAssertNil(weakPayload)
        XCTAssertEqual(releases.value, 1)
    }

    func testAV1CodecConfigurationIsDerivedFromSequenceHeaderOBU() throws {
        let accessUnit = Data([
            0x12, 0x00, // temporal delimiter OBU
            0x0A, 0x10, 0x00, 0x00, 0x00, 0x43, 0xFC, 0x13,
            0xFC, 0x0B, 0x3C, 0x02, 0x4E, 0x88, 0x30, 0x30, 0x30, 0xA0,
        ])
        let parsed = try AV1AccessUnit(
            data: accessUnit,
            profile: VideoCodecProfile(codecMask: 0x1000)
        )
        XCTAssertEqual(
            parsed.sequenceHeaderOBU,
            Data([
                0x0A, 0x10, 0x00, 0x00, 0x00, 0x43, 0xFC, 0x13,
                0xFC, 0x0B, 0x3C, 0x02, 0x4E, 0x88, 0x30, 0x30, 0x30, 0xA0,
            ])
        )
        XCTAssertEqual(Array(parsed.codecConfigurationRecord.prefix(4)), [0x81, 0x08, 0x0C, 0x00])
        XCTAssertEqual(parsed.codecConfigurationRecord.dropFirst(4), parsed.sequenceHeaderOBU)
    }
}

private final class MediaFormatLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }

    func increment() {
        lock.withLock { storedValue += 1 }
    }
}
