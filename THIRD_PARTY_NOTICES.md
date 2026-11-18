# 第三方依赖 / Third-party dependencies

## Microsoft Edge WebView2

Windows 宿主使用 Microsoft Edge WebView2 SDK 与 WebView2 Runtime。构建脚本从 NuGet 获取开发库，本仓库不提交 SDK 二进制文件。

- 包：`Microsoft.Web.WebView2`，构建版本 `1.0.4191.47`。
- 包与许可信息：https://www.nuget.org/packages/Microsoft.Web.WebView2/1.0.4191.47
- 文档：https://learn.microsoft.com/microsoft-edge/webview2/

WebView2 及 Windows / .NET Framework 组件适用各自的许可条款，不因本项目的 GPL-3.0 许可而变更。

The host uses the Microsoft Edge WebView2 SDK and Runtime. SDK binaries are downloaded by the build script and are not checked into this repository. Microsoft components retain their respective licenses.

## NSIS

Windows 安装包使用 NSIS 3.13 制作。便携编译器仅在构建时下载，不作为项目源码提交。NSIS 及其压缩模块适用各自许可，详见 https://nsis.sourceforge.io/License 。安装包附带项目对应源码 ZIP。

## Natural Earth (themes/wind/coast.json)
Coastlines and lakes cropped and simplified from Natural Earth 1:50m "land" and "lakes" (naturalearthdata.com). Public domain.

## Open-Meteo (Wind Map, live data)
Wind data fetched at runtime from api.open-meteo.com, licensed CC BY 4.0. Weather data by Open-Meteo.com.


## three.js (themes/lib/three)
three.js r169 (core module, GLTFLoader, DRACOLoader, RoomEnvironment, BufferGeometryUtils and the Draco decoder), MIT License, © 2010–2024 three.js authors. See themes/lib/three/LICENSE. Used by the Wind Tunnel to render its models once.

## Wind Tunnel models (themes/tunnel/models)
- `x1.glb`: Bell X-1, Smithsonian National Air and Space Museum (3d.si.edu), CC0.
- `shuttle.glb`: Orbiter Space Shuttle OV-103 Discovery, Smithsonian NASM, CC0 (textures resized to 2048 px).
- `wright.glb`: 1903 Wright Flyer, Smithsonian NASM, CC0 (textures resized; colour applied in the theme).
- `x57.glb`: NASA X-57 Maxwell, NASA 3D Resources (github.com/nasa/NASA-3D-Resources), public domain; no NASA endorsement implied.
- `cat.glb`: "Concrete Cat Statue", Poly Haven (polyhaven.com), CC0 (packed to GLB, textures resized).
- `car.glb`: "Car Concept", Khronos glTF Sample Assets, CC BY 4.0 — © The Khronos Group; based on "Free Concept Car 004" by Unity Fan (CC0). Khronos logos and trademarks are not licensed. Textures resized.
- `apollo.glb`: Command Module, Apollo 11 (exterior), Smithsonian NASM, CC0 (textures resized).
- `fish.glb`: "Barramundi Fish", Khronos glTF Sample Assets, CC0 (textures resized).
- `horse.glb`, `shark.glb`, `whale.glb`, `ray.glb`: "Horse Statue 01", "Bronze Shark Statue", "Bronze Whale Statue", "Bronze Ray Statue", Poly Haven, CC0 (packed to GLB; statue stands cut away in the theme).

## Gallery (themes/gallery)
- `wall.jpg`, `frame_*.png`, `plate.png`: generated for this theme with Google Gemini (Nano Banana Pro), then keyed and sliced locally.
- `art/*.jpg`: public-domain paintings and prints from The Metropolitan Museum of Art Open Access (CC0): Van Gogh, *Wheat Field with Cypresses* (1889) and *Self-Portrait with a Straw Hat* (1887); Hokusai, *The Great Wave off Kanagawa* (ca. 1830–32); Vermeer, *Young Woman with a Water Pitcher* (ca. 1662); Seurat, *Circus Sideshow* (1887–88); Cézanne, *The Card Players* (1890–92); Sargent, *Madame X* (1883–84); Turner, *Venice, from the Porch of Madonna della Salute* (ca. 1835); Degas, *The Dance Class* (1874); Bruegel the Elder, *The Harvesters* (1565). Resized to 1800 px.

## Painted textures (Snowfall, Meadow, Beach)
`themes/snow/backdrop.jpg`, `themes/meadow_grass.jpg` and `themes/beach_sand.jpg` were generated for these themes with Google Gemini (Nano Banana Pro) and made seamless locally.

## Model Railway (themes/railway/)

The building and tree atlases (`houses.webp`, `trees.webp`, `atlas.json`) are original stylized toy-model renders generated
for Tidewall with Google Gemini (gemini-3-pro-image), then keyed and cut out by hand. No third-party artwork or trademarks
are reproduced. Everything else on the board (land, water, track, trains, cars, boats, balloon) is drawn in code.

## Tidewall app icon and interface (assets/, themes/ui/)

The app icon artwork was generated for Tidewall with Google Gemini (gemini-3-pro-image) and shaped into the macOS icon
grid by hand. The theme thumbnails in themes/ui/thumbs are renders of Tidewall's own themes.
