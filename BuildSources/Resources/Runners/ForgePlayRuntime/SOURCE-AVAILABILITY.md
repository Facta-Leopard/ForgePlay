# Wine 11.12 deployed-runtime identity

- Validated corresponding source tree SHA-256: `ef83e1a9c2c31db1c712b12a6253676f61e316f2c6373e0702ef57926291aa32`
- Packaged ForgePlay patch-set SHA-256: `d8545f36ab0b13399182171c0c1f6e899fbb7245d7be57f793b060b20bb2fb0f`

This identifies the notarized 1.3 (Build 4) runtime in the adjacent unchanged
RuntimeManifest.json. SOURCE-IDENTITY.json and Config identify the separately
supplied copyright-normalized sources; no new binary build is claimed.
After rebuilding Wine, use the newly packaged runtime's matching manifest and
source-availability record before building its runnable native Game Mode host.
Preserve the GPL/LGPL notices in LICENSE.txt, WINE-GAME-MODE-NOTICE.txt and LICENSES/.
