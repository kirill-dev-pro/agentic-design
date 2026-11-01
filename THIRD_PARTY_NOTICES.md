# Third-party notices

Agentic Design includes the following software and data. The release app ships this file
in `Agentic Design.app/Contents/Resources/`.

| Component | Where | License |
| --- | --- | --- |
| NanoVG (Mikko Mononen), Odin port | `src/nanovg/` (vendored, modified: see `src/nanovg/README.md`) | zlib |
| fontstash (Mikko Mononen), Odin port | `src/fontstash/` (vendored, modified) | zlib |
| Odin core and vendor libraries (wgpu bindings, GLFW bindings) | compiled in; `src/wgpu/` | zlib |
| GLFW | linked into the app (from the Odin release) | zlib |
| wgpu-native | linked into the app (downloaded by `tools/fetch_wgpu.sh`) | MIT or Apache-2.0 (used under MIT) |
| stb_image (Sean Barrett) | linked into the app (Odin `vendor:stb`) | public domain or MIT |
| Lucide icons | `assets/lucide.txt` | ISC, `assets/LICENSE-lucide.txt` |
| Noto Sans (Google) | `assets/fonts/` | SIL Open Font License 1.1, `assets/fonts/OFL-NotoSans.txt` |
| Inter (The Inter Project Authors), JetBrains Mono (JetBrains) | `designs/sample/fonts/`, fonts of the sample design | SIL Open Font License 1.1, `designs/sample/fonts/OFL-*.txt` |

## NanoVG

```
Copyright (c) 2013 Mikko Mononen memon@inside.org

This software is provided 'as-is', without any express or implied
warranty.  In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
claim that you wrote the original software. If you use this software
in a product, an acknowledgment in the product documentation would be
appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.

```

## fontstash

```
Copyright (c) 2013 Mikko Mononen memon@inside.org

This software is provided 'as-is', without any express or implied
warranty.  In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
claim that you wrote the original software. If you use this software
in a product, an acknowledgment in the product documentation would be
appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.

```

## Odin (core and vendor packages)

```
Copyright (c) 2016-2025 Ginger Bill. All rights reserved.

This software is provided 'as-is', without any express or implied
warranty. In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
```

## GLFW

```
Copyright (c) 2002-2006 Marcus Geelnard

Copyright (c) 2006-2019 Camilla Löwy

This software is provided 'as-is', without any express or implied
warranty. In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would
   be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not
   be misrepresented as being the original software.

3. This notice may not be removed or altered from any source
   distribution.

```

## wgpu-native

```
MIT License

Copyright (c) 2021 The gfx-rs developers

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## stb_image

```
stb_image is available under either the MIT license or the public domain (Unlicense),
at the user's choice. Copyright (c) 2017 Sean Barrett.

Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
to whom the Software is furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.
```

## Lucide and Noto Sans

See `assets/LICENSE-lucide.txt` (ISC) and `assets/fonts/OFL-NotoSans.txt` (SIL OFL 1.1).
