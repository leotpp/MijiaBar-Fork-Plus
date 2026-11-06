import Foundation
import Testing
import CoreGraphics
@testable import MijiaCore
@testable import MijiaBarApp

@MainActor @Suite struct HouseAutoRoomsTests {
    @Test func classicStylesSelectComposedDoorways() throws {
        let saved = HouseLayoutSolver.classicFour.map { HouseLayoutCell(room: "room-\($0.module)", module: $0.module, col: $0.col, row: $0.row) }
        let roomKeys = Dictionary(uniqueKeysWithValues: saved.map { ($0.module, $0.room) })
        let expected = Set(["bedroom-study", "bedroom-living", "generic-living", "living-study"])
        for style in HouseStyles.all where style.hasClassicArt {
            for phase in [HousePhase.day, .night] {
                let (catalog, _) = try #require(HouseModuleAssets.load(phase: phase, style: style.id))
                for layout in [nil, saved, HouseLayoutSolver.setAllLevels(saved, flat: true)] as [[HouseLayoutCell]?] {
                    let source = try #require(HouseSceneSource.make(layout: layout, phase: phase, style: style.id, roomKeys: roomKeys))
                    let cells = try #require(source.layout)
                    #expect(cells == HouseLayoutSolver.setAllLevels(saved, flat: true))
                    #expect(!source.byRoom)
                    #expect(Set(source.scene.modules.keys) == Set(saved.map(\.module)))
                    let composed = try #require(HouseModuleAssets.composedScene(layout: cells, phase: phase, style: style.id))
                    #expect(source.unlit === composed.unlit && source.lit === composed.lit)
                    let origin = try #require(source.scene.origin)
                    let coverage = HouseDoorwayPlanner.coverage(layout: cells, catalog: catalog)
                    #expect(coverage.uncovered.isEmpty)
                    #expect(coverage.doorways.count == 4)
                    #expect(Set(coverage.doorways.map { [$0.back.module, $0.front.module].sorted().joined(separator: "-") }) == expected)
                    for door in coverage.doorways {
                        #expect(!door.stairs)
                        let point = HouseComposer.doorwayPoint(door, along: door.center, elevation: 20, originX: Int(origin[0]), originY: Int(origin[1]))
                        let front = try #require(source.scene.modules[door.front.module])
                        let polygons = try #require(front.visible)
                        let path = CGMutablePath()
                        for polygon in polygons {
                            path.addLines(between: polygon.map { CGPoint(x: $0[0], y: $0[1]) }); path.closeSubpath()
                        }
                        #expect(!path.contains(CGPoint(x: point.x, y: point.y), using: .evenOdd))
                    }
                }
                var elevated = saved; elevated[0].level = 1
                let source = try #require(HouseSceneSource.make(layout: elevated, phase: phase, style: style.id))
                #expect(source.byRoom && source.layout == elevated)
                #expect(HouseDoorwayPlanner.plan(layout: elevated, catalog: catalog).contains { $0.stairs })
            }
        }
    }

    @Test func effectiveCellsReachSceneDecorAndPetWorldWithoutSaving() throws {
        let model = AppModel(mock: true)
        model.addHouseFixtureDemo()
        let home = model.houseHomeKey
        let layout = try #require(model.houseLayoutCells)
        #expect(model.house.homes[home]?.layout == nil)
        #expect(layout.contains { $0.module == "kitchen" })
        #expect(Set(model.houseResolved.rooms.map(\.key)) == Set(layout.map(\.room)))
        let source = try #require(HouseSceneSource.make(layout: layout, phase: .day, style: model.houseStyle))
        #expect(source.byRoom)
        #expect(source.layout == layout)
        #expect(Set(source.scene.modules.keys) == Set(layout.map(\.room)))
        let decorRooms = Set((source.scene.decorSlots ?? []).map(\.room))
        #expect(decorRooms.isSubset(of: Set(layout.map(\.room))))
        let session = try #require(HousePetSceneSession(source: source, layout: model.houseLayoutCells,
                                                       style: model.houseStyle, config: HomeHouse(), rooms: model.houseRooms))
        let petRooms = Set(session.world.nodes.map(\.room))
        #expect(petRooms == Set(layout.map(\.room)))
        let classic = model.houseClassicLayout
        model.houseEdit("classic") { $0.setLayout(home: home, layout: classic) }
        #expect(model.houseLayoutCells == nil)
        #expect(model.houseResolved.rooms.allSatisfy { HouseCatalog.classicModules.contains($0.module) })
        model.houseUndoStep(redo: false)
        #expect(model.houseLayoutCells == layout)
        #expect(model.house.homes[home]?.layout == nil)
    }

    @Test func runtimeLoaderHasExtraModulesInEveryStyleAndPhase() throws {
        for style in HouseStyles.all {
            for phase in [HousePhase.day, .night] {
                let (catalog, images) = try #require(HouseModuleAssets.load(phase: phase, style: style.id))
                for module in ["kitchen", "bathroom", "balcony"] {
                    #expect(catalog.modules[module] != nil)
                    #expect(images[module] != nil, "\(style.id)/\(module)/\(phase)")
                }
            }
        }
    }
}
