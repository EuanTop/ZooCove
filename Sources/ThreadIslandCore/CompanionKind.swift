import Foundation

public enum CompanionKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case capybara, bee, platypus, mallard
    case redPanda = "red-panda"
    case otter, axolotl
    case barnOwl = "barn-owl"
    case chinchilla, frog
    case arcticFox = "arctic-fox"
    case octopus, hedgehog, koi, penguin
    case leafSheep = "leaf-sheep"

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .capybara: "卡皮巴拉"
        case .bee: "蜜蜂"
        case .platypus: "鸭嘴兽"
        case .mallard: "绿头鸭"
        case .redPanda: "小熊猫"
        case .otter: "海獭"
        case .axolotl: "六角恐龙"
        case .barnOwl: "仓鸮"
        case .chinchilla: "龙猫"
        case .frog: "树蛙"
        case .arcticFox: "北极狐"
        case .octopus: "章鱼"
        case .hedgehog: "刺猬"
        case .koi: "锦鲤"
        case .penguin: "企鹅"
        case .leafSheep: "叶羊海蛞蝓"
        }
    }
}
