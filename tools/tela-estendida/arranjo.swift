import CoreGraphics
import Foundation
var n: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &n)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
CGGetOnlineDisplayList(n, &ids, &n)
for id in ids {
    let b = CGDisplayBounds(id)
    let ativo = CGDisplayIsActive(id) != 0
    let espelho = CGDisplayMirrorsDisplay(id)
    print("id=\(id) vendor=0x\(String(CGDisplayVendorNumber(id), radix: 16)) x=\(Int(b.minX))..\(Int(b.maxX)) y=\(Int(b.minY))..\(Int(b.maxY)) principal=\(CGDisplayIsMain(id) != 0) ativo=\(ativo) espelhoDe=\(espelho)")
}
