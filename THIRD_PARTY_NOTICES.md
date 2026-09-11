# Third-party notices

Umbra includes or links the following software. Complete license texts for
vendored code are retained beside its source under `Vendor/`.

- moonlight-common-c — GNU General Public License 3.0.
- ENet (Moonlight fork) — MIT License.
- nanors (Moonlight fork) — MIT License.
- OpenSSL 3.5.7 LTS — Apache License 2.0.
- Opus 1.6.1 — BSD 3-Clause License.
- wolfSSL 5.9.2 — separately licensed commercial dependency; public source
  provenance and downstream licensing requirements are recorded below.
- libSRTP 2.8.0 with the LizardByte wolfCrypt backend — BSD 3-Clause License.

Release archives must include the corresponding source for GPL-covered code or
a GPL-compliant written offer/source link, along with the exact build scripts
and dependency versions used for the binary.

Umbra application bundles include the complete redistributable license texts
as `LICENSE`, `OpenSSL-Apache-2.0.txt`, `Opus-BSD-3-Clause.txt`,
`moonlight-common-c-GPL-3.0.txt`, `ENet-MIT.txt`, and `nanors-MIT.txt` beside
this file. The commercial wolfSSL agreement and every confidential licensing
artifact remain external; only the public provenance and downstream licensing
notice below are distributed. The complete libSRTP and added wolfCrypt-backend
notices are reproduced below.

## wolfSSL 5.9.2

Umbra's LSP security provider is built from the public wolfSSL 5.9.2 stable
source release:
<https://github.com/wolfSSL/wolfssl/tree/ac01707f552c611fbd135cc723b2682b3e7f80f2>

Umbra release builds use wolfSSL and wolfCrypt under a separately held
commercial license. The commercial agreement, account information,
credentials, and other confidential license material are not part of the
source tree or application bundle.

wolfSSL 5.9.2 is otherwise offered under the GNU General Public License,
version 3, subject to the exceptions in wolfSSL's upstream `LICENSING` file,
or under a commercial license from wolfSSL Inc. A downstream builder or
distributor that incorporates wolfSSL must independently obtain the required
commercial rights or comply with the applicable wolfSSL GPL terms. Umbra's
GPL-3.0 license does not grant wolfSSL commercial rights.

## libSRTP 2.8.0

Copyright (c) 2001-2017 Cisco Systems, Inc.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of Cisco Systems, Inc. nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

## libSRTP wolfCrypt backend

The AES-GCM and AES-ICM wolfCrypt backend added to libSRTP carries this
additional notice:

Copyright (c) 2026 LizardByte project contributors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
