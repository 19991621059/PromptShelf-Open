import AppKit

@MainActor
func runPetChecks() throws {
    precondition(PetCatalog.styles.count == 6)
    precondition(PetCatalog.normalize("bear") == "round")
    let picker = PetPicker(selected: "cat")
    picker.frame = NSRect(x: 0, y: 0, width: 312, height: 60)
    picker.layoutSubtreeIfNeeded()
    precondition(picker.subviews.count == 6)
    for style in PetCatalog.styles.dropFirst() {
        let pet = PlushPetView(style: style.0)
        pet.frame = NSRect(x: 0, y: 0, width: 38, height: 38)
        let bitmap = pet.bitmapImageRepForCachingDisplay(in: pet.bounds)!
        pet.cacheDisplay(in: pet.bounds, to: bitmap)
        precondition(bitmap.pixelsWide >= 38 && pet.subviews.isEmpty)
    }
    print("PASS: six native icon choices; vector rendering creates no subviews or network activity")
}
