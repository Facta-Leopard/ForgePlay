# ForgePlay layered artwork

Created on 2026-09-23 with the built-in image generation tool for ForgePlay's
website redesign. The references were ForgePlay's existing rabbit-blacksmith
hero and manifesto images. These are separate image layers, not screenshots
of a functioning app. No OriginKit media, code or shader was copied.

## Active assets

- `workshop.jpg`: painted workshop background (2172 × 724).
- `smith.png`: transparent rabbit, hammer, tongs and anvil (1254 × 1254).
- `tools.png`: transparent foreground tools (2172 × 724).
- `outlook-landscape.jpg`: valley beyond the forge (1254 × 1254).
- `outlook-rabbit.png`: transparent rear-view rabbit with hammer (1254 × 1254).
- `outlook-door.png`: transparent open doorway (1254 × 1254).

Opaque generated backgrounds were encoded as JPEG at quality 86; cutout PNGs
retain their original alpha. CSS controls framing and depth; canvas adds subtle
embers. Reduced-motion users get a still composition.

## Prompt specifications

Shared direction: mature hand-painted gouache/oil game illustration, deliberate
matte brushwork, grey/cream rabbit blacksmith with long ears and worn leather
apron, slate-blue shadows and copper light. No text, watermarks, logos, green
or purple magic ribbons, or glossy plastic rendering.

Workshop: remove rabbit, anvil, pedestal and foreground tool rack from the
new painterly reference; reconstruct an empty workshop with blue upper-right
light, copper forge fire at far right and quiet left-third negative space.
Panoramic 3:1; center-right left empty for separate character placement.

Smith: transparent cutout of the same rabbit, hammer in one paw, tongs in the
other, hot steel on a plain anvil and short base. Focused gaze toward work.
Preserve complete ears, hammer/tong grips and whole silhouette with margins.
Square canvas; no room, floor rectangle or extra props.

Tools: transparent 3:1 foreground with three worn steel tools and a wooden
block restricted to the lower-right, plus a shallow bottom workbench edge.
Left 80% and upper half remain transparent. Dark soft painterly shapes with
one copper rim; center unobstructed.

Outlook landscape: square background only, looking out from a stone forge
threshold toward a rugged valley and blue mountains in mist; a restrained
copper path threads into the distance under early horizon light. Ground in
lower third, no character or foreground door.

Outlook rabbit: transparent full-body cutout of the same character, seen from
behind and slightly three-quarter, looking out over the valley. Plain hammer
hangs down, other paw relaxed, cream tail, leather straps and boots. Copper
rim from the right and soft cool light. Complete ears and feet; no scenery.

Outlook door: transparent square foreground overlay, weathered forge jambs
limited to the left 12% and right 15%, slim threshold in bottom 10%. Center
and top opening transparent. Open heavy wood/iron doors, hammered hinge,
subdued copper-lit edges and bold dark brushwork. No character or landscape.
