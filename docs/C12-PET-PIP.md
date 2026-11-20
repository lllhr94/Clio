# C12 小克与肉包的画中画调研

## 可行性

iOS 15 起，`AVPictureInPictureController.ContentSource` 可以接收 `AVSampleBufferDisplayLayer`。Clio 的最低版本是 iOS 26，现有 `PetSheets` 已能裁出宠物包的 RGBA 单帧。可以把裁好的帧以最近邻画进固定尺寸的 `CVPixelBuffer`，再配上单调递增的时间戳生成 `CMSampleBuffer`，交给显示层。后台播放状态由 `AVPictureInPictureSampleBufferPlaybackDelegate` 提供。启动前同时查设备支持和当下是否允许启动，等待系统回调确认成功。播放器小窗的大小、停靠位置、控制按钮和与其他 PiP 的切换由系统决定。原图的透明背景也应先合成在 Clio 的纸色底上，系统小窗没有透明桌宠形状的保证。见 [Apple 自定义播放器 PiP 指南](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player) · [样本缓冲内容源](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class/init(samplebufferdisplaylayer:playbackdelegate:)) · [播放代理](https://developer.apple.com/documentation/avkit/avpictureinpicturesamplebufferplaybackdelegate)。

先验证用户点按钮后能否启动，并在切到主屏幕、另一个 App 后继续播。支持条件满足时可以尝试系统的自动启动属性，仍应保留手动路径。普通后台定时器、`TimelineView` 或 `scenePhase` 自身都不承诺持续运行。收到 PiP 停止、播放中断或进入不支持的状态时停掉帧生产，回前台继续用现有 `PetStage`。见 [启动条件](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/ispictureinpicturepossible) · [自动启动属性](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/canstartpictureinpictureautomaticallyfrominline)。

## 权限与签名

- 需要在 App 声明 Background Modes 的 Audio, AirPlay, and Picture in Picture。当前 Clio 工程没有这个声明。配套验证 `AVAudioSession` 的播放类别及前后台、录音和听写切换。像素帧来自本机宠物包，不需要申请麦克风、相机、照片库或录屏权限。见 [Apple PiP 设置说明](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player) · [播放音频会话](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback)。
- PiP API 本身没有单独的受管授权申请。后台声明随 `Info.plist` 打进 App，签名仍须满足 iOS 安装要求。开发者签名和常用自签工具是否能以 Clio 的当前配置工作，需要各用真机验证。仓库 CI 的 unsigned IPA 只能验证编译和打包。不要仅凭模拟器、小窗 API 可调用或重新签名成功就承诺能后台播放。
- App Store 审核条款 2.5.4 要求后台能力仅用于其规定用途。宠物动画能否作为 PiP 内容通过审核没有公开保证。首轮只验证正常的系统 PiP 生命周期，避免用静音音轨或后台任务延长 App 活跃。见 [Apple App Store 审核指南 2.5.4](https://developer.apple.com/app-store/review/guidelines/#software-requirements)。

## 耗电与真机验证

- 平时尽量沿用实际帧时长。小克 idle 三帧一轮 1.45 秒，平均约每秒两次帧切换。原型先用固定 96×96 的像素缓冲池，重复帧复用缓冲，后台空闲限制帧率，系统停止 PiP 就关闭生产。验证低提交频率时显示层能否连续播放，再决定是否需要按固定频率补帧。实际耗电取决于系统合成、调度、屏幕亮度与前台 App，当前没有实测数字。
- 同一台 iPhone、同亮度、同前台场景，对比关闭和开启各 15 分钟。记录 Energy Log 或 Power Profiler、CPU 唤醒次数、内存、掉帧与热状态。再检查主屏幕和其他 App 切换、锁屏解锁、低电量模式、其它播放器抢占、关小窗和回来打开语音。用开发签名与常用自签方案各验证一次。见 [Apple 能耗调试指南](https://developer.apple.com/documentation/xcode/monitoring-your-app-s-power-use)。

批准后建议首个原型只显示选中宠物的闲坐动画，接在「宠物设置」的开关下，默认关。先取得真机生命周期与能耗结果，再接工作、批准等状态。
