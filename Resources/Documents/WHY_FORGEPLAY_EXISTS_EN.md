## Why ForgePlay Exists

ForgePlay is not a CrossOver clone. Windows gaming on macOS had settled around CrossOver as the default commercial answer, and with almost no like-for-like competitor, CodeWeavers grew comfortable with its existing architecture and product priorities. I started ForgePlay because I was dissatisfied with that complacency.

I did not want to make that argument with slogans. I built a different system and released the code so that anyone can inspect the result.

### CrossOver's contribution and its complacency are separate issues

CodeWeavers has made major, long-running contributions to Wine. It has released a substantial amount of CrossOver-related Wine work upstream and has played an important role in sustaining the Wine ecosystem. That deserves recognition.

It does not place the current product beyond criticism.

For ordinary macOS users, CrossOver has effectively been the only commercial reference point that combines ongoing development, technical support, a GUI, installation automation, per-game configuration, and proprietary component integration such as D3DMetal. Free frontends and community projects have existed, but very few comparable products have competed under the same conditions for any sustained period.

Without a serious competitor, a product has less reason to question its own architecture. Users have fewer places to go, so there is less pressure to adopt new execution models or integrate platform-specific features before anyone else does. Over time, one company's choices begin to look like the limits of the entire ecosystem.

CrossOver became complacent in that environment. Implementation difficulty, QA cost, staffing, and support scope are real constraints, but they do not explain this gap. With real like-for-like competition, CrossOver would have had to test its assumptions more aggressively, and deeper macOS integration would have become a competitive requirement much earlier.

ForgePlay was started to create the competition that had been missing.

### Why was Game Mode not a first-class feature already?

A product that sells Windows gaming on macOS should have investigated how to connect its game sessions to macOS Game Mode. This is not a secret API or an exotic idea. The game can run through a dedicated macOS app context that owns and manages the lifecycle of the live Wine session.

Yet CodeWeavers' current public documentation does not present Game Mode as a supported per-game CrossOver feature. D3DMetal, DXMT, DXVK, DLSS, MSync, and other graphics or synchronization options are documented in detail, while integration with macOS's own gaming execution model is not treated as a core product capability.

ForgePlay creates a dedicated **Game Host** for each game. That host owns the Wine-based game session from launch through termination. During actual gameplay, macOS Game Overlay and the menu bar report Game Mode as active for that Game Host. This is not a game category attached to the main ForgePlay launcher. The host that owns and manages the active game session is recognized by macOS as the game.

Performance gains can be measured per game. What ForgePlay has already demonstrated is that **a Wine-based Windows game can be connected correctly to the macOS Game Mode execution context.**

So the obvious question is:

> If an independent developer could identify and implement this design, why did a company with decades of commercial Wine experience not do it first?

Whether CodeWeavers failed to consider it or considered it unimportant, the result for users was the same: CrossOver did not offer this option for years.

Weak competition is one of the main reasons that omission could persist. With a serious competitor, leaving an obvious macOS gaming integration outside the product for so long would have been much harder. CrossOver could remain the market reference point without changing its execution model, so there was room to decide that there was no urgent reason to change it.

ForgePlay's Game Host is not a rhetorical complaint about that complacency. It is a working counterexample.

### Treating macOS as a gaming platform, not merely as a Wine launcher

CrossOver is effective at packaging Wine and graphics translation layers. A macOS gaming product should go further than launching Wine binaries.

The following should be managed as one per-game execution system:

- app lifecycle;
- Game Mode;
- fullscreen behavior;
- prefixes and launch settings;
- graphics backends;
- environment variables;
- logs and diagnostics; and
- cleanup after the game exits.

ForgePlay organizes these responsibilities around the per-game Game Host. It does not treat macOS as a desktop on which Wine happens to run. Its core design places Windows games inside a macOS-native game execution structure.

### Compatibility should not remain a black box

Compatibility is not established because an executable opens once. Real compatibility includes video, input, audio, networking, frame consistency, clean termination, and reproducibility after updates.

CrossOver's proprietary per-game data and automatic configuration are valid commercial choices. The cost is opacity. Users often cannot see exactly which settings were applied, why a title works or fails, or what changed after an update.

ForgePlay isolates execution environments and settings per game and exposes the applied configuration and runtime logs. It does not pretend that every game works. It prioritizes a more useful standard: success and failure should be reproducible, traceable, and explainable.

Compatibility should be a technical result that users can inspect, not merely a rating handed down by a company.

### The issue is not bundling GPTK; it is the lack of clarity around commercial authority

ForgePlay also bundles Wine and GPTK. Bundling GPTK or D3DMetal in a combined distribution is therefore not the criticism.

In the official Game Porting Toolkit distribution I downloaded from Apple Developer Downloads, the bundled `License.rtf` limited redistribution under that developer license to non-commercial purposes. ForgePlay is currently an open-source project rather than a paid product, and it does not present GPTK or D3DMetal as ForgePlay-owned open-source components. Each bundled version is managed as a separate third-party component under the license shipped with that version.

CodeWeavers publicly states that CrossOver 26 includes D3DMetal 3.0, and CrossOver is sold as a paid product.

That leaves one direct question for CodeWeavers:

> **Does CodeWeavers hold a separate commercial agreement or redistribution authorization that permits D3DMetal to be included in paid CrossOver releases and distributed to end users?**

No one needs confidential pricing or the full contract. If the authority exists, CodeWeavers can say that it exists and identify the general product or version scope. Leaving the commercial rights for a third-party component inside a paid product publicly unclear creates unnecessary opacity.

ForgePlay applies the same standard to itself. If its distribution model or revenue model changes, the license attached to the GPTK and D3DMetal versions in use will be reviewed again. ForgePlay will not assume rights that the applicable license does not grant.

### Why open source

ForgePlay is open source because criticism should be testable.

- The Game Host architecture should be inspectable.
- The execution context that activates Game Mode should be reviewable.
- Per-game settings and prefixes should be visible.
- Performance and compatibility claims should be verifiable against code and logs.
- Failures and limitations should not be hidden.

The official ForgePlay project remains maintainer-led and does not currently accept code contributions. Subject to the applicable licenses, anyone may inspect the source, fork it, or develop a separate implementation.

CrossOver chose a proprietary product. ForgePlay chooses openness: expose the architecture, expose the results, and let users compare them directly.

### If there was no competitor, build one

CodeWeavers' contributions to Wine deserve respect. They do not make CrossOver's current architecture the final answer for the ecosystem.

Whether CodeWeavers failed to think of a Game Host design or simply chose not to prioritize it, the practical outcome was the same. Users had no comparable option, and the lack of competition allowed that gap to remain for years.

That is one of the main reasons ForgePlay exists.

> **If the incumbent did not think of it because there was no competitor, someone else can think of it.**  
> **If the incumbent did not build it because there was no competitor, a new competitor can build it.**

ForgePlay is not a slogan aimed at CrossOver. It is an implementation of choices CrossOver did not make, released so that the results can be tested in public.

ForgePlay exists to put competition where there was none.

---

### References

- [CrossOver 26 announcement — includes Wine 11.0 and D3DMetal 3.0](https://www.codeweavers.com/blog/mjohnson/2026/2/10/crossover-26-cures-artificial-incompatibility-with-windows-games-on-mac)
- [CrossOver Mac User Guide](https://support.codeweavers.com/en_US/crossover-mac-user-guide)
- [Advanced Settings in CrossOver Mac 26](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26)
- [CodeWeavers Open Source page — proprietary components in CrossOver](https://www.codeweavers.com/open-source)
- [CodeWeavers CrossOver page — upstream release of Wine development code](https://www.codeweavers.com/crossover/)
- [Apple Game Porting Toolkit — official page](https://developer.apple.com/games/game-porting-toolkit)
- [Game Porting Toolkit packages on Apple Developer Downloads](https://developer.apple.com/download/all/?q=game%20porting%20toolkit) — Apple Developer sign-in is required. The license discussion above is based on the author's direct review of the `License.rtf` bundled with an official distribution.
- [Apple Game Mode documentation](https://support.apple.com/en-us/105118)
- [Apple Developer — `LSSupportsGameMode`](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsgamemode)
