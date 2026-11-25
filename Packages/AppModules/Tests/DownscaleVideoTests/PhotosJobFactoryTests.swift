import AppCore
import Foundation
import MediaEngine
import PhotosLibrary
import Testing

@testable import DownscaleVideo

@Suite struct PhotosJobFactoryTests {
    private let base = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal)

    @Test func eachVideoGetsAPhotosJobWithItsOwnPresetAndName() throws {
        let jobs = PhotosJobFactory.makeJobs(
            for: [("A/L0/001", "IMG_1.MOV", .smaller), ("B/L0/001", "IMG_2.MOV", .high)], settings: base,
            destination: .replace, lost: ["A/L0/001": ["Cinematic depth data"]])

        #expect(jobs.count == 2)
        #expect(jobs.allSatisfy { $0.toolID == DownscaleTool.photosToolID && $0.sourceBookmark.isEmpty })
        #expect(PhotoAssetURL.identifier(from: jobs[0].source) == "A/L0/001")
        let first = try JSONDecoder().decode(DownscaleJobSettings.self, from: jobs[0].settings)
        let second = try JSONDecoder().decode(DownscaleJobSettings.self, from: jobs[1].settings)
        #expect(first.preset == .smaller && second.preset == .high)
        #expect(first.photosDestination == .replace && second.photosDestination == .replace)
        #expect(first.photosFileName == "IMG_1.MOV")
        #expect(first.predictedLost == ["Cinematic depth data"])
        #expect(second.predictedLost == [])
    }

    @Test func noPredictionIsRecordedAsNone() throws {
        let jobs = PhotosJobFactory.makeJobs(
            for: [("A", "a.mov", .balanced)], settings: base, destination: .newAsset)
        let settings = try JSONDecoder().decode(DownscaleJobSettings.self, from: jobs[0].settings)
        #expect(settings.predictedLost == nil)
        #expect(settings.photosDestination == .newAsset)
    }

    @Test func aSettingsFileWithoutPhotosFieldsStillDecodes() throws {
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .replace)
        let decoded = try JSONDecoder().decode(DownscaleJobSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.photosDestination == nil && decoded.photosFileName == nil)
    }

    @Test func lossNamesCoverCinematicAndHDRForH264Only() {
        #expect(PhotosLossCheck.lostNames(isCinematic: true, isHDR: false, custom: nil) == ["Cinematic depth data"])
        #expect(PhotosLossCheck.lostNames(isCinematic: false, isHDR: true, custom: nil).isEmpty)
        let h264 = DownscaleSpec(targetShortSide: 1080, averageBitRate: 5_000_000, codec: .h264Compatible)
        #expect(PhotosLossCheck.lostNames(isCinematic: false, isHDR: true, custom: h264) == ["HDR details"])
        #expect(PhotosLossCheck.lostNames(isCinematic: false, isHDR: false, custom: h264).isEmpty)
    }
}
