## Why I Built ForgePlay

ForgePlay was not built to clone CrossOver.

For users who want to run Windows games on macOS without a virtual machine or a separate Windows installation, CrossOver has long been the only serious commercial reference point. Free frontends and community projects have existed, but almost no equivalent competitor has combined sustained development, technical support, installation automation, per-game configuration, and graphics translation layers in one product.

That lack of competition is exactly what bothered me.

When a product has no serious rival, it does not have to reconsider its own assumptions. Users have nowhere comparable to go, so the pressure to build new features first or replace an aging architecture becomes weaker. I believe CrossOver became complacent in that environment.

I did not want to stop at criticism. If another architecture was possible, I had to build it and release enough of it for others to inspect the code and test the result. That is how ForgePlay began.

### I have seen what happens when competition disappears

I am a former Korean civil servant. In Korea, a civil-service position is often called an **iron rice bowl**: a job with very little risk of dismissal and, barring serious misconduct, employment until retirement.

For roughly ten years, I worked mainly in departments that most people tried to avoid. I saw firsthand what happens when an organization loses both competitive pressure and any meaningful threat to its survival.

When problems appeared, dividing responsibility came before solving them. Delaying a decision and preserving the existing procedure were safer than changing anything. The organization did not disappear when the same failures repeated, and an individual's livelihood was rarely threatened by the absence of improvement. Change therefore became optional work that somebody had to volunteer to carry.

I came to believe that this was not a problem that individual diligence could solve. The structure shaped the behavior. I eventually left the supposedly secure career because I had lost faith in that culture.

The lesson I took from it is simple:

> **Without a threat to survival, change becomes optional. Without competition, improvement slows and unresolved problems become routine.**

Just as survival pressure drives evolution, competitive pressure drives products to change. Without a credible alternative, there is no rival testing whether the current approach is still good enough and less reason to improve before being forced to.

I asked the same question about CrossOver:

> **Did CodeWeavers become comfortable with the existing model because it had no equivalent competitor?**

My answer is yes.

### Returning 95% does not erase the other 5%

CodeWeavers has contributed to Wine for many years. It has upstreamed a substantial amount of work developed for CrossOver and has played an important role in sustaining the Wine ecosystem. That contribution deserves recognition.

But CodeWeavers also advertises CrossOver with this statement:

> **“95% of the Wine code base we develop for CrossOver gets released back into the Wine project for the open source community.”**[^crossover-95]

That sentence is both a boast and an admission. **Ninety-five percent is not one hundred.** By CodeWeavers' own figure, some Wine code developed for CrossOver does not become part of the shared Wine upstream.

The point should not be blurred. The LGPL requires corresponding source when a modified Wine binary is distributed, but it does not require every modification to be merged into the WineHQ upstream.[^lgpl] If the remaining five percent is included in CrossOver's FOSS source archive, that fact alone does not prove an LGPL violation.

But **minimum legal compliance is not the same as returning work to the commons.**

Publishing a source archive for each release is not equivalent to placing changes upstream where they can be reviewed, maintained, and regression-tested as part of the shared project. A patch left downstream must be found, separated, rebased onto newer Wine versions, and revalidated by every independent project that wants to use it. Source code existing somewhere is not the same as the community being able to reuse and advance it in practice.

CodeWeavers also says on its open-source page that it develops Wine work directly against upstream and submits that work upstream first.[^crossover-95] Then the remaining five percent should be easy to account for. Was it rejected upstream, too product-specific to merge, still being prepared, or deliberately retained as CrossOver-only downstream work? The current marketing celebrates the 95% while saying nothing about what the other 5% contains or why it remains outside the shared upstream.

> **CodeWeavers is free to build a business on the Wine commons, but it cannot ask to be praised for returning “most” of its improvements while treating the remainder as if it did not exist. If 95% is the claim, the other 5% requires an account.**

Providing corresponding source because the LGPL requires it is **license compliance**. Placing changes in the shared upstream so that everyone can review, maintain, and build on them is **ecosystem reciprocity**. Those are not the same thing and should not be marketed as though they were.

The objection is not that CodeWeavers earns money from a proprietary interface, compatibility database, or separately licensed commercial components. The objection is that it builds on the Wine community's work, leaves part of its own improvements and operational knowledge as a product advantage, and then invokes “support for open source” as though that ended the discussion.

Past contribution does not place the current CrossOver product beyond criticism. Nor does contribution to Wine make CrossOver's architecture the final answer for Windows gaming on macOS.

CrossOver is a paid product. Customers are not paying merely for Wine binaries. They are paying for a macOS-specific execution model, per-game validation, support when something breaks, and regression management after updates.

Implementation difficulty, QA cost, and limited staffing are real constraints. Competition is what changes priorities inside those constraints. With an equivalent competitor, deeper integration with macOS-specific capabilities would have become a central product feature much earlier.

CrossOver could preserve its existing architecture without losing its position because no equivalent rival existed. I believe that environment enabled its complacency.

### Game Mode was foreseeable, buildable, and still left undone

A product sold for gaming on macOS should have treated integration with macOS Game Mode as an obvious engineering task.

Game Mode gives a game higher priority for CPU and GPU resources, reduces interference from background work, and lowers latency for wireless controllers and audio devices. It is not merely a feature for raising peak FPS; it is an operating-system mechanism for improving frame consistency and responsiveness.[^game-mode]

CrossOver 26 documents D3DMetal, DXMT, DXVK, DLSS, MSync, and other graphics and synchronization features in detail. It does not present per-game Game Mode integration as a product feature.[^crossover-settings]

ForgePlay creates an independent macOS **Game Host** for each game. The Game Host launches Wine and the actual Windows game process, then owns and manages the game session from start to finish. When the game enters fullscreen, macOS recognizes that Game Host as the game and activates Game Mode normally.

This is not a cosmetic game category attached to the ForgePlay launcher. The process that owns the real game session participates in the macOS game execution model.

The architecture is not secret and does not require exceptional privileges. It is a design that a macOS gaming product could reasonably have considered. I considered it, implemented it, and verified that it works.

CodeWeavers has spent decades building a commercial Wine product and still did not turn this into a product feature.

If it never considered the design, its product architecture had hardened. If it considered the design and dismissed it, its priorities had hardened. The result is the same.

> **This was not technically impossible. It simply did not have to be done first while no competitor was forcing the issue.**

With an equivalent rival, this gap would not have survived for long. If one product advertised Game Mode integration, the other would have had to answer with a better implementation. But there was no equivalent rival and no one was forcing CodeWeavers to move.

I call that complacency enabled by weak competition.

ForgePlay's Game Host is not a rhetorical response to that judgment. It is a working one.

### macOS should be treated as a gaming platform, not merely a place to launch Wine

A macOS gaming product should not stop after spawning Wine processes.

Each game should be managed as one execution system that includes:

- a per-game application lifecycle;
- Game Mode;
- fullscreen transitions;
- prefixes and launch settings;
- graphics backends;
- environment variables;
- logs and diagnostics; and
- cleanup after the game exits.

ForgePlay organizes those elements around a per-game Game Host. It does not treat macOS as a desktop on which Wine happens to run. Its basic design is to manage Windows games inside the macOS gaming execution model.

### Do not transfer compatibility responsibility to users and the community

A paid compatibility product should take responsibility for per-game regression testing and for defining the scope of official support.

It should not rely on user ratings, community tips, external DLLs, registry changes, and manual configuration to solve launch failures, broken video, stuttering, input, audio, and launcher problems, then present the result as if it were compatibility delivered by the product itself.

CodeWeavers' Compatibility Database combines staff and community submissions, while its Tips pages state that community and Advocate information is not official support.[^compatibility-database] Shared knowledge is useful. The problem begins when it pushes the QA and support obligations of a paid product into the background.

User reports should supplement QA, not replace it. Community workarounds should supplement official fixes, not hide the absence of them.

At minimum, CodeWeavers should distinguish clearly between these states:

- the game works with default CrossOver settings;
- the game requires an official CodeWeavers configuration;
- the game requires a community workaround;
- the game requires an external DLL or unofficial patch;
- video, input, networking, or other features remain broken; and
- the game works only in a specific release or has suffered a regression.

If a game is unsupported, it should be marked as unsupported. If a manual workaround is required, that condition should be displayed as prominently as the compatibility rating.

When a customer pays for the product and then has to diagnose the failure, change settings, install outside patches, and feed the result back into the database, the boundary between product responsibility and unpaid community labor has already collapsed.

### Compatibility should not remain a black box

Compatibility is not established because an executable opens once. Real compatibility includes video, input, audio, networking, frame consistency, clean termination, and reproducibility after updates.

CrossOver's private per-game configuration and graphics-backend database is a legitimate commercial choice.[^crossover-proprietary] The cost is opacity. Users often cannot determine exactly which settings were applied, why a game works or fails, or what changed after an update.

ForgePlay separates the execution environment and configuration for each game. It records the applied configuration and runtime logs so that both success and failure can be reproduced. It does not claim that every game works. Instead of hiding failures, it prioritizes a structure that makes them traceable and capable of leading to the next fix.

Compatibility should be an inspectable technical result, not merely a rating issued by a company.

### Guard against the de facto privatization of open-source Wine

Wine itself remains open source. This is not an accusation that CodeWeavers has legally taken ownership of Wine or closed its source code.

But de facto privatization does not require the source to become completely closed. A company can build on the community upstream while dispersing the last pieces that create the product gap across downstream patches, private data, proprietary components, and opaque redistribution authority. The legal core can remain open while practical control becomes concentrated in one company.

The concern is a structure in which the practical ability to use Wine for gaming on macOS becomes concentrated in:

- CrossOver-specific Wine changes that remain outside the shared upstream and must be extracted, rebased, and revalidated by other implementations;
- proprietary components;
- private per-game compatibility data;
- commercial redistribution authority that is not publicly confirmed;
- development priorities controlled by one company; and
- installation and execution systems managed by that company.

CodeWeavers' 95% claim does not answer this concern. It confirms that some CrossOver-related Wine work remains outside the shared upstream. Even when that code is legally reusable from a release source archive, the cost of locating it, porting it to current Wine, and testing the regressions is shifted to independent developers. CodeWeavers already has the integrated and tested result inside its product.

> **An open core can still become a private moat when the last mile is kept downstream, proprietary, data-locked, or opaque.**

If that structure hardens, Wine may remain open in source form while its practical value to ordinary users becomes dependent on one commercial product. A closed operational layer becomes the only realistic entrance to an open-source core.

That is what I mean by the **de facto privatization of open-source Wine**. It is not a claim that legal ownership has been transferred. It is a criticism of a structure that freely absorbs the community foundation while leaving the modifications, data, and integration capacity that create the practical product gap difficult for other implementations to reproduce.

CodeWeavers may be one of Wine's most important contributors, but it is not the owner of the Wine ecosystem. Years of contribution do not entitle one company to determine the direction and priorities of Wine gaming on macOS by default.

A company that promotes the value of open source should also respect independent projects and competitors that use the same foundation to experiment, build different architectures, and criticize the incumbent product. It should not use the 95% contribution as a shield to dismiss the competitive gap created by the other 5%, private compatibility knowledge, and proprietary components.

Wine becomes stronger when multiple implementations and distribution models compete. A structure in which one commercial product remains the only practical answer weakens the openness that gives Wine its value.

### The issue is not bundling GPTK; it is transparency about commercial authority

ForgePlay also bundles Wine and GPTK. Bundling GPTK or D3DMetal in a combined distribution is therefore not the criticism.

The `License.rtf` included with the GPTK distribution bundled in ForgePlay limits redistribution under that developer license to non-commercial purposes.[^gptk-license] ForgePlay is currently released without a purchase price, and access is not conditioned on payment or sponsorship. It does not present GPTK or D3DMetal as ForgePlay-owned open-source components; they remain separate third-party components governed by the license shipped with them.

CodeWeavers publicly states that CrossOver 26 includes D3DMetal 3.0, and CrossOver is sold as a paid product.[^crossover26]

That leaves one direct question for CodeWeavers:

> **Does CodeWeavers hold a separate commercial agreement or redistribution authorization that permits D3DMetal to be included in paid CrossOver releases and distributed to end users?**

No one is asking for confidential pricing or the full contract. If the authority exists, CodeWeavers can confirm that it exists and identify the products and versions to which it applies.

There is no reason to leave the commercial redistribution basis for a major third-party component inside a paid product publicly unclear. If CodeWeavers presents itself as a supporter of open source and software freedom, it should provide at least minimal transparency about the commercial authority underlying its own distribution.

ForgePlay applies the same standard to itself. If its distribution or revenue model changes, the licenses attached to the GPTK and D3DMetal versions in use will be reviewed again. ForgePlay will not assume rights that the applicable license does not grant.

### Why ForgePlay is open source

ForgePlay is open source because criticism should be testable.

If I claim that CrossOver became complacent without serious competition, I must first show that another architecture can actually work.

- The Game Host architecture should be inspectable.
- The process in which Game Mode activates should be reviewable.
- Per-game prefixes and settings should be visible.
- Performance and compatibility claims should be verifiable through code and logs.
- Failures and limitations should not be hidden.

The official ForgePlay project remains maintainer-led and does not currently accept code contributions. Subject to the applicable licenses, anyone may inspect the source, fork it, or develop a separate implementation.

CrossOver chose a commercial product that includes proprietary components. ForgePlay chooses to publish its own code, expose the architecture and the result, and let users compare them directly.

ForgePlay is not exempt from this standard. For every Wine modification, it should state which changes reached upstream and which remain ForgePlay-specific, and it should publish the reasons, complete patch set, and build materials for anything left downstream. **It will not use “most of it is open” to obscure the exceptions that matter.**

### If there is no competitor, build one

I left a career described as an iron rice bowl because I had already seen how an organization hardens when unresolved problems carry no survival cost.

I did not want to accept the same complacency as inevitable in software.

CodeWeavers' contribution to Wine deserves respect. It does not make CrossOver's current architecture the final answer for the ecosystem. Any organization or product that remains the reference point for too long without meaningful competition will harden.

CodeWeavers' 95% figure is evidence of contribution. It is also evidence of a limit: the remaining 5% stays outside the shared upstream. When that gap is combined with private compatibility data, proprietary components, and opaque commercial authority for D3DMetal, an open-source core can be turned from a common foundation into a commercial moat controlled by one company.

The Game Host and Game Mode implementation is a concrete example. An independent developer identified and implemented an architecture that CodeWeavers never turned into a product feature. It was not technically impossible. It simply did not have to be prioritized while no equivalent competitor existed.

The dependence on community workarounds, the concentration of practical knowledge in private data, and the lack of clarity around commercial redistribution authority reflect the same underlying problem. When competition is weak, the pressure to explain and improve is weak as well.

That dissatisfaction is one of the main reasons ForgePlay exists.

> **If the incumbent did not think of it because there was no competitor, I will think of it.**  
> **If the incumbent did not build it because there was no competitor, I will build it.**

ForgePlay is not a slogan aimed at CrossOver. It is an implementation of choices CrossOver did not make, released so that the result can be tested in public.

> **If the lack of competition caused progress to stop, the answer is to create competition.**

ForgePlay exists to begin that competition.

[^crossover-95]: CodeWeavers, [CrossOver](https://www.codeweavers.com/crossover), [Open Source](https://www.codeweavers.com/open-source), and [CrossOver Source Code](https://www.codeweavers.com/crossover/source). CodeWeavers states that 95% of the Wine code base it develops for CrossOver is released back into the Wine project, separately states that Wine work is submitted upstream first, and provides release-specific FOSS source archives.
[^lgpl]: GNU Project, [GNU Lesser General Public License, version 2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html), especially Sections 2, 4, and 6. The license requires corresponding source for distributed modified library code but does not require acceptance or merger into a particular upstream repository.
[^game-mode]: Apple, [Use Game Mode on Mac](https://support.apple.com/en-us/105118) and [`LSSupportsGameMode`](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsgamemode).
[^crossover-settings]: CodeWeavers, [Advanced Settings in CrossOver Mac 26](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26).
[^compatibility-database]: CodeWeavers, [The Compatibility Database](https://support.codeweavers.com/en_US/the-compatibility-database) and [CrossOver Tips notice](https://www.codeweavers.com/compatibility/crossover/tips/codeweavers-crossover/bottles-and-installing).
[^crossover-proprietary]: CodeWeavers, [Open Source](https://www.codeweavers.com/open-source) and [Advanced Settings in CrossOver Mac 26](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26).
[^gptk-license]: `License.rtf` included with the official Game Porting Toolkit distribution bundled in ForgePlay, Sections 1, 2.A, and 2.C.
[^crossover26]: CodeWeavers, [CrossOver 26 announcement](https://www.codeweavers.com/blog/mjohnson/2026/2/10/crossover-26-cures-artificial-incompatibility-with-windows-games-on-mac).
