import 'package:flutter/foundation.dart';

/// Registers the SIL Open Font License for the bundled JetBrains Mono and for
/// 霞鹜文楷 (LXGW WenKai), which 设置 › 主题 › 字体 downloads on first use.
///
/// OFL 1.1 requires the licence to travel with the font; the APK bundles the font
/// (pubspec `fonts:`) but not `assets/fonts/OFL.txt`, so the text is embedded here
/// and shown on the open-source licences page next to the other third-party
/// notices (`registerThirdPartyLicenses()`). WenKai's notice is listed whether or
/// not it has been downloaded.
void registerFontLicenses() {
  LicenseRegistry.addLicense(
    () => Stream<LicenseEntry>.fromIterable(const [
      LicenseEntryWithLineBreaks(<String>['JetBrains Mono'], _jetbrainsMonoOfl),
      LicenseEntryWithLineBreaks(<String>['LXGW WenKai'], _wenKaiOfl),
    ]),
  );
}

/// Verbatim copy of `assets/fonts/OFL.txt`.
const _jetbrainsMonoOfl =
    r'''
Copyright 2020 The JetBrains Mono Project Authors (https://github.com/JetBrains/JetBrainsMono)

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
https://scripts.sil.org/OFL


''' +
    _oflBody;

/// Where the release `lib/state/font_state.dart` downloads comes from, then a
/// verbatim copy of its `OFL.txt` (https://github.com/lxgw/LxgwWenKai/blob/v1.530/OFL.txt).
const _wenKaiOfl =
    r'''
霞鹜文楷 LXGW WenKai v1.530 (LXGWWenKai-Regular.ttf, LXGWWenKai-Medium.ttf), unmodified,
downloaded on first use from https://github.com/lxgw/LxgwWenKai/releases/tag/v1.530

''' +
    _wenKaiNotice +
    _oflBody;

const _wenKaiNotice = r'''
Copyright 2021-2026 LXGW (https://github.com/lxgw/LxgwWenKai), with Reserved Font Name '霞鹜', '霞鶩', '落霞孤鹜', '落霞孤鶩' and 'LXGW'. [ADDITIONAL PERMISSION] The Reserved Font Names '霞鹜', '霞鶩', '落霞孤鹜', '落霞孤鶩' and 'LXGW' may continue to be used in Modified Versions recompiled from the Original Version, without modifications to the font source code; or in Modified Versions subsetted or converted to other formats (e.g., WOFF/WOFF2) solely for web font delivery, provided such Modified Versions are not made available as installable desktop fonts (e.g., on mainstream platforms like Google Fonts, or third-party non-commercial platforms recognized by the author @lxgw; other web font platforms please contact the author @lxgw for confirmation).
Copyright 2020 The Klee Project Authors (https://github.com/fontworks-fonts/Klee)

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
https://openfontlicense.org


''';

/// The licence itself, the same in both fonts' OFL.txt.
const _oflBody = r'''
-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded, 
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
''';
