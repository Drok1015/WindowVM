# WindowVM 应用图标

使用内置 image_gen 工具生成，深蓝圆角底板与悬浮玻璃窗口，背景透明。

- `AppIcon-source.png`：生成原图。
- `AppIcon.png`：1024 × 1024 主图。
- `AppIcon.icns`：macOS 多尺寸图标，包含 16–1024px。
- `../scripts/build-icon.sh`：使用 sips 与 iconutil 重新生成 ICNS。

应用构建脚本将图标复制到资源目录，并通过 CFBundleIconFile 注册；应用首页也使用相同图标。已经运行的应用需重新打开以刷新图标。

## 生成提示词

Use case: logo-brand. Asset type: production macOS application icon for WindowVM, a lightweight Windows virtual machine app for Mac. Generate ONE finished square 1024x1024 icon, not a mockup or contact sheet. A beautifully crafted rounded-square macOS tile with a deep midnight blue enamel surface, holding two offset floating rounded rectangular window panes: rear pane frosted translucent cyan glass, front pane luminous soft ice blue with a distinctive simple four-pane window cutout, conveying a Windows desktop living inside a Mac. An original symbol, not a copy of Microsoft or Parallels branding. Quiet premium industrial design, gently dimensional sculpted edges, subtle top-left studio lighting, restrained blue/cyan palette, excellent bold silhouette readable at 16px. Front-facing centered composition, tile occupies about 86% of canvas width with even generous transparent outside margins and a small soft contact shadow. Fully transparent outside the rounded-square tile. No text, letters, numbers, monitor stands, arrows, tiny UI controls, extra objects, background scene, watermarks or border frame.
