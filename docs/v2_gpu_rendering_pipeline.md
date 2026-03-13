## GPU 渲染管线设计

为了支持全新的实体化相机架构，GPU 渲染管线（iOS Metal / Android OpenGL ES）必须设计为高度模块化和动态可组合的架构。

### 1. 管线阶段划分

渲染管线分为 **基础相机效果 (Base Effects)** 和 **选项效果 (Option Effects)** 两部分。

#### 1.1 基础相机效果 (由 BaseModel 驱动)
这些效果是相机的物理固有属性，始终存在，无法被用户关闭：
1. **Sensor Simulation (传感器模拟)**：基于 `sensor.type`、`iso` 和 `dynamicRange` 模拟底噪、动态范围裁剪（如高光压平或暗部死黑）。
2. **Base Color Science (基础色彩科学)**：基于 `color.lut`、`temperature` 和 `tint` 进行全局色彩重映射和白平衡偏移。
3. **Base Optical (基础光学)**：基于 `optical.focalLength` 和 `aperture` 计算基础的景深模糊程度（可选）。

#### 1.2 选项效果 (由 OptionGroups 驱动)
这些效果根据用户当前选择的胶卷、镜头、相纸等动态叠加：
1. **Film LUT & Tone Curve (胶卷色彩与色调)**：基于 `FilmOption` 叠加专属 LUT 和 S曲线。
2. **Film Grain (胶卷颗粒)**：基于 `FilmOption.grainIntensity` 叠加动态噪点纹理。
3. **Lens Effects (镜头缺陷)**：基于 `LensOption` 叠加：
   - Vignette (暗角)
   - Distortion (畸变)
   - Chromatic Aberration (色差/RGB分离)
   - Highlight Bloom / Halation (高光溢出/光晕)
   - Flare (镜头眩光)
4. **Scan Artifacts (扫描/数字伪影)**：如 VHS 录像带的扫描线、CCD 的 JPEG 压缩伪影。
5. **Paper Frame (相纸边框)**：基于 `PaperOption` 在画面外围叠加拍立得边框纹理和纸张质感。**（注：相纸效果必须在拍照前预览时就可见，并且在按下快门后直接渲染到最终保存的图像中，实现“拍完即得”，无需后期再次选择）**。
6. **Watermark (水印)**：基于 `WatermarkOption` 在指定位置叠加时间戳、品牌 Logo 或 REC 标识。

### 2. 动态管线组合流程

当 Flutter 侧向原生层发送 `setCameraConfig` 指令时，原生层会根据传入的完整配置（BaseModel + 选中的 Options）动态拼装 Shader Pass。

```text
[ Camera Frame (YUV -> RGB) ]
        │
        ▼
[ PASS 1: Sensor & Base Color ]  <-- 基础模型
  - 传感器噪声模拟
  - 基础白平衡与 Base LUT
        │
        ▼
[ PASS 2: Film Simulation ]      <-- FilmOption
  - Film LUT 映射
  - 色调曲线调整
  - 动态胶卷颗粒 (Grain)
        │
        ▼
[ PASS 3: Lens Optics ]          <-- LensOption
  - 畸变 (Distortion)
  - 色差 (Chromatic Aberration)
  - 暗角 (Vignette)
        │
        ▼
[ PASS 4: Bloom & Halation ]     <-- LensOption (需要降采样和模糊计算)
  - 提取高光 -> 模糊 -> 叠加回主图
        │
        ▼
[ PASS 5: Artifacts ]            <-- 特殊相机效果 (如 VHS)
  - 扫描线 / 录像带噪点
        │
        ▼
[ PASS 6: Paper & Frame ]        <-- PaperOption / RatioOption
  - 按照 Ratio 裁剪画幅
  - 叠加相纸边框纹理 (Paper Texture)
        │
        ▼
[ PASS 7: Watermark ]            <-- WatermarkOption
  - 渲染文字或 Logo 纹理并叠加
        │
        ▼
[ Export to Texture (Preview) / Save to Disk (Photo) ]
```

### 3. 性能优化策略

1. **Pass 合并 (Uber Shader)**：在移动端，过多的 Render Pass 会导致极大的带宽开销。我们将 Pass 1、2、3 和 5 合并为一个巨大的 "Uber Shader"（超级着色器），通过 Uniform 变量（宏定义或分支）控制各功能的开关。
2. **Bloom 独立 Pass**：由于高光溢出（Bloom）需要进行高斯模糊（多次采样），必须作为独立的 Pass 运行（先降采样，再模糊，再升采样叠加）。
3. **相纸与水印的 Alpha Blending**：相纸边框和水印本质上是 2D 纹理的叠加，可以直接在最后一个绘制 Pass 中使用标准的 Alpha 混合完成。
4. **预览与导出分离**：
   - 预览时：在较低分辨率（如 720p/1080p）下运行全套管线，保证 60fps。
   - 拍照时：在后台线程使用全分辨率（如 12MP）图像重新跑一遍管线，应用完全相同的 Uniform 参数，然后将最终结果（包含已选的相纸边框和水印）直接编码为 JPEG 保存到相册。
