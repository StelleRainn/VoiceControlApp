import SwiftUI
import Speech
import AVFoundation
import Combine

// MARK: - App Entry Point
@main
struct VoiceControlApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Rule Model
struct VoiceRule: Codable, Identifiable {
    let content: String
    let text: String
    let audio: String
    let action: String
    
    var id: String { content }
}

struct RulesConfig: Codable {
    let wakeup: String
    let responseText: String
    let responseAudio: String
    let rules: [VoiceRule]
    
    enum CodingKeys: String, CodingKey {
        case wakeup
        case responseText = "response-text"
        case responseAudio = "response-audio"
        case rules
    }
}

// MARK: - App State
enum AppState {
    case idle           // 监听唤醒词
    case listening      // 等待命令
    case processing     // 处理命令
    case responding     // 回复中
    
    var displayText: String {
        switch self {
        case .idle: return "等待唤醒..."
        case .listening: return "请说出指令"
        case .processing: return "处理中..."
        case .responding: return "执行中..."
        }
    }
    
    var color: Color {
        switch self {
        case .idle: return Color(red: 0.4, green: 0.5, blue: 0.6)
        case .listening: return Color(red: 0.2, green: 0.5, blue: 1.0)
        case .processing: return Color(red: 1.0, green: 0.6, blue: 0.2)
        case .responding: return Color(red: 0.2, green: 0.8, blue: 0.4)
        }
    }
    
    var saturation: Double {
        switch self {
        case .idle: return 0.3
        case .listening: return 0.7
        case .processing: return 0.8
        case .responding: return 0.9
        }
    }
}

// MARK: - Voice Manager
class VoiceManager: NSObject, ObservableObject {
    @Published var state: AppState = .idle
    @Published var statusMessage: String = "初始化中..."
    @Published var lastCommand: String = ""
    @Published var lastResponse: String = ""
    
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var speechSynthesizer = AVSpeechSynthesizer()
    
    private var rulesConfig: RulesConfig?
    private var isAuthorized = false
    private var isListening = false
    
    // 用于追踪状态切换时间,防止缓存文字干扰
    private var lastStateChangeTime: Date = Date()
    private var transcriptBufferStartTime: Date = Date()
    
    // 调优参数 - 可根据需要调整
    private let stateTransitionDelay: TimeInterval = 0.2  // 状态切换延迟 (秒) - 减小以提高响应速度
    private let restartListeningDelay: TimeInterval = 0.5 // 重启监听延迟 (秒)
    private let responseReturnDelay: TimeInterval = 2.5   // 响应后返回监听延迟 (秒)
    private let transcriptIgnoreWindow: TimeInterval = 1.0 // 忽略状态切换前的文字 (秒)
    
    override init() {
        self.audioEngine = AVAudioEngine()
        self.speechSynthesizer = AVSpeechSynthesizer()
        super.init()
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        self.speechSynthesizer.delegate = self
        self.loadRules()
    }
    
    // MARK: - Load Rules
    private func loadRules() {
        guard let url = Bundle.main.url(forResource: "rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(RulesConfig.self, from: data) else {
            statusMessage = "规则文件加载失败"
            return
        }
        rulesConfig = config
        statusMessage = "规则加载成功"
    }
    
    // MARK: - Request Permissions
    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                if status == .authorized {
                    self?.isAuthorized = true
                    self?.statusMessage = "权限已授予"
                    self?.startMonitoring()
                } else {
                    self?.statusMessage = "需要麦克风权限"
                }
            }
        }
    }
    
    // MARK: - Start Monitoring (Idle State)
    func startMonitoring() {
        state = .idle
        lastStateChangeTime = Date()
        statusMessage = "监听唤醒词中..."
        startListening()
    }
    
    // MARK: - Stop Listening Completely
    private func stopListening() {
        isListening = false
        
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        recognitionTask?.cancel()
        recognitionTask = nil
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }
    
    // MARK: - Speech Recognition
    private func startListening() {
        guard isAuthorized else { return }
        guard !isListening else { return }
        
        stopListening()
        
        // 减小延迟以提高响应速度
        DispatchQueue.main.asyncAfter(deadline: .now() + stateTransitionDelay) { [weak self] in
            self?.doStartListening()
        }
    }
    
    private func doStartListening() {
        guard isAuthorized else { return }
        
        isListening = true
        transcriptBufferStartTime = Date() // 重置缓冲开始时间
        
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("音频会话配置失败: \(error)")
            isListening = false
            return
        }
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            isListening = false
            return
        }
        recognitionRequest.shouldReportPartialResults = true
        
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()
        
        let inputNode = audioEngine.inputNode
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            var isFinal = false
            
            if let result = result {
                let transcript = result.bestTranscription.formattedString
                isFinal = result.isFinal
                
                // 只处理状态稳定后的文字,忽略切换时的缓存
                let timeSinceStateChange = Date().timeIntervalSince(self.lastStateChangeTime)
                if timeSinceStateChange > self.transcriptIgnoreWindow {
                    self.processTranscript(transcript)
                }
            }
            
            if error != nil || isFinal {
                self.stopListening()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + self.restartListeningDelay) {
                    if self.state == .idle && self.isAuthorized {
                        self.startListening()
                    }
                }
            }
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("音频引擎启动失败: \(error)")
            stopListening()
            isListening = false
        }
    }
    
    // MARK: - Process Transcript
    private func processTranscript(_ transcript: String) {
        let normalized = transcript.replacingOccurrences(of: " ", with: "")
        
        switch state {
        case .idle:
            // 只检测唤醒词,忽略命令词
            if let wakeup = rulesConfig?.wakeup, normalized.contains(wakeup) {
                // 检查是否在唤醒词之前出现了命令词 - 如果是,忽略命令词
                let wakeupRange = (normalized as NSString).range(of: wakeup)
                let textBeforeWakeup = (normalized as NSString).substring(to: wakeupRange.location)
                
                // 检查唤醒词前是否有命令词
                var hasCommandBeforeWakeup = false
                if let rules = rulesConfig?.rules {
                    for rule in rules {
                        if textBeforeWakeup.contains(rule.content) {
                            hasCommandBeforeWakeup = true
                            break
                        }
                    }
                }
                
                // 如果唤醒词前有命令词,延长忽略窗口
                if hasCommandBeforeWakeup {
                    lastStateChangeTime = Date()
                }
                
                state = .listening
                lastStateChangeTime = Date() // 更新状态切换时间
                lastCommand = ""
                statusMessage = "已唤醒,等待指令..."
                
                if let responseText = rulesConfig?.responseText {
                    speak(responseText)
                }
                
                stopListening()
                // 减小延迟以提高响应速度
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.startListening()
                }
            }
            
        case .listening:
            // 只匹配命令规则,确保不会误触发
            if let rule = rulesConfig?.rules.first(where: { normalized.contains($0.content) }) {
                // 验证这确实是一个新的命令,而不是之前缓存的
                let timeSinceBufferStart = Date().timeIntervalSince(transcriptBufferStartTime)
                guard timeSinceBufferStart > 0.5 else { return } // 忽略刚开始监听时的文字
                
                state = .processing
                lastStateChangeTime = Date()
                lastCommand = rule.content
                lastResponse = rule.text
                statusMessage = "执行: \(rule.content)"
                
                stopListening()
                executeRule(rule)
            }
            
        default:
            break
        }
    }
    
    // MARK: - Execute Rule
    private func executeRule(_ rule: VoiceRule) {
        state = .responding
        lastStateChangeTime = Date()
        
        if !rule.action.isEmpty {
            performAction(rule.action)
        }
        
        speak(rule.text)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + responseReturnDelay) { [weak self] in
            guard let self = self else { return }
            self.state = .idle
            self.lastStateChangeTime = Date()
            self.statusMessage = "等待下次唤醒..."
            self.startListening()
        }
    }
    
    // MARK: - Perform Action
    private func performAction(_ action: String) {
        switch action {
        case "turn_on_light":
            toggleFlashlight(on: true)
        case "turn_off_light":
            toggleFlashlight(on: false)
        default:
            break
        }
    }
    
    // MARK: - Flashlight Control
    private func toggleFlashlight(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            statusMessage = "设备不支持手电筒"
            return
        }
        
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch {
            statusMessage = "手电筒控制失败: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Text to Speech
    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.5
        speechSynthesizer.speak(utterance)
    }
    
    deinit {
        stopListening()
    }
}

// MARK: - Speech Synthesizer Delegate
extension VoiceManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // 语音播放完成
    }
}

// MARK: - Content View
struct ContentView: View {
    @StateObject private var voiceManager = VoiceManager()
    @State private var animationAmount: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            // 全局渐变背景 - 根据状态动态变化颜色和饱和度
            AnimatedGradientBackground(
                color: voiceManager.state.color,
                saturation: voiceManager.state.saturation
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 100)
                
                // 状态指示器
                VStack(spacing: 30) {
                    // 动画圆圈
                    ZStack {
                        // 外圈光晕
                        Circle()
                            .fill(
                                RadialGradient(
                                    gradient: Gradient(colors: [
                                        voiceManager.state.color.opacity(0.3),
                                        Color.clear
                                    ]),
                                    center: .center,
                                    startRadius: 80,
                                    endRadius: 120
                                )
                            )
                            .frame(width: 240, height: 240)
                            .blur(radius: 10)
                        
                        // 中间圆环
                        Circle()
                            .stroke(voiceManager.state.color.opacity(0.5), lineWidth: 3)
                            .frame(width: 180, height: 180)
                        
                        // 内圆
                        Circle()
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        voiceManager.state.color.opacity(0.4),
                                        voiceManager.state.color.opacity(0.2)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 140, height: 140)
                        
                        // 麦克风图标
                        Image(systemName: microphoneIcon)
                            .font(.system(size: 50, weight: .light))
                            .foregroundColor(.white)
                            .shadow(color: voiceManager.state.color.opacity(0.5), radius: 10)
                    }
                    .scaleEffect(animationAmount)
                    .onChange(of: voiceManager.state) { _ in
                        // 状态变化时触发动画
                        withAnimation(.easeInOut(duration: 0.3)) {
                            animationAmount = 1.05
                        }
                        withAnimation(.easeInOut(duration: 0.3).delay(0.3)) {
                            animationAmount = 1.0
                        }
                    }
                    .onAppear {
                        // 聆听状态持续脉动
                        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                            if voiceManager.state == .listening {
                                animationAmount = 1.08
                            }
                        }
                    }
                    
                    // 状态文本 - 增加间距避免冲突
                    VStack(spacing: 12) {
                        Text(voiceManager.state.displayText)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 2)
                        
                        Text(voiceManager.statusMessage)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                            .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
                    }
                }
                
                Spacer()
                
                // 命令历史
                VStack(alignment: .leading, spacing: 12) {
                    if !voiceManager.lastCommand.isEmpty {
                        CommandBubble(
                            icon: "text.bubble.fill",
                            iconColor: .blue,
                            label: "指令",
                            content: voiceManager.lastCommand
                        )
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    
                    if !voiceManager.lastResponse.isEmpty {
                        CommandBubble(
                            icon: "speaker.wave.2.fill",
                            iconColor: .green,
                            label: "回复",
                            content: voiceManager.lastResponse
                        )
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 50)
            }
        }
        .onAppear {
            voiceManager.requestPermissions()
        }
    }
    
    private var microphoneIcon: String {
        switch voiceManager.state {
        case .idle: return "mic.slash"
        case .listening: return "mic"
        case .processing: return "waveform.circle"
        case .responding: return "speaker.wave.2"
        }
    }
}

// MARK: - Animated Gradient Background
struct AnimatedGradientBackground: View {
    let color: Color
    let saturation: Double
    
    var body: some View {
        ZStack {
            // 基础渐变
            LinearGradient(
                gradient: Gradient(colors: [
                    color.opacity(0.6),
                    color.opacity(0.3),
                    Color.black
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            // 动态光晕层
            RadialGradient(
                gradient: Gradient(colors: [
                    color.opacity(saturation * 0.4),
                    Color.clear
                ]),
                center: .topTrailing,
                startRadius: 0,
                endRadius: 400
            )
            
            RadialGradient(
                gradient: Gradient(colors: [
                    color.opacity(saturation * 0.3),
                    Color.clear
                ]),
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 350
            )
        }
        .animation(.easeInOut(duration: 0.8), value: color)
        .animation(.easeInOut(duration: 0.8), value: saturation)
    }
}

// MARK: - Command Bubble
struct CommandBubble: View {
    let icon: String
    let iconColor: Color
    let label: String
    let content: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(iconColor)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                
                Text(content)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 2)
    }
}

// MARK: - Preview
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
