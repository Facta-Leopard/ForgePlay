# Color style references

ForgePlay's numbered color styles reference Figma's public
[100 color combinations](https://www.figma.com/resource-library/color-combinations/)
and its [Korean edition](https://www.figma.com/ko-kr/resource-library/color-combinations/),
observed on 2026-10-18. Figma and the original article/artwork belong to Figma, Inc.

The application contains the reference numbers, short palette names and RGB color
values. It does not bundle Figma's original illustrations, logos, article prose,
website code or an SDK. ForgePlay implements the selection UI, previews and
light/dark semantic-color adjustment in its own SwiftUI code. Figma does not
sponsor or endorse this feature. This reference does not grant a license to the
original article or artwork or change ForgePlay's existing source licenses.

Printed HEX labels are used instead of compressed image pixel colors, with one
documented exception: Golden hour (#22) prints the invalid five-digit `#CC550`;
the final swatch uses its observed flat RGB `#EDEDC8`. Retro calm is #78 in the
Korean source and sequential list; the English article's duplicate #50 is not
used as an identifier. Palette IDs remain 1–100 across languages.

Original research inputs and hashes are retained outside app resources under
`Artifacts/Inputs/Design/FigmaColorCombinations-20261018/`. They are not distribution
assets. There is no runtime network dependency or additional third-party package.
