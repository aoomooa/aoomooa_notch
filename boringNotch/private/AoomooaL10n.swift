//
//  AoomooaL10n.swift — 设置窗口里枚举选项的中文名
//
//  这些枚举的 rawValue 会被存进 UserDefaults，不能改；界面上显示这里的中文名。
//

import Foundation

extension MediaControllerType {
    var displayName: String {
        switch self {
        case .nowPlaying: return "系统正在播放（任意 App）"
        case .appleMusic: return "Apple 音乐"
        case .spotify: return "Spotify"
        case .youtubeMusic: return "YouTube Music"
        }
    }
}

extension SneakPeekStyle {
    var displayName: String {
        switch self {
        case .standard: return "默认"
        case .inline: return "内嵌"
        }
    }
}

extension OptionKeyAction {
    var displayName: String {
        switch self {
        case .openSettings: return "打开系统设置"
        case .showHUD: return "显示浮窗"
        case .none: return "不做任何事"
        }
    }
}

extension SliderColorEnum {
    var displayName: String {
        switch self {
        case .white: return "白色"
        case .albumArt: return "跟随封面"
        case .accent: return "强调色"
        }
    }
}
