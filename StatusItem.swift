// В StatusItem.swift
private static let icon: NSImage? = {
    let image = NSImage(named: "MenuBarIcon")
    image?.isTemplate = true
    return image
}()
//...
if let button = item.button {
    button.image = Self.icon // <-- Вот здесь она устанавливается
    //...
}
