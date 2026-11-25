import CoreGraphics
import Foundation
import LocalLibrary
import Testing

@testable import PhotosLibrary

/// Holds a fetch until the test lets it go.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

@MainActor
@Suite struct PhotosLibraryFacadeTests {
    private static let noIndex: PhotosLibrary.IndexLoader = { ([:], .noAccess) }

    private func asset(_ number: Int, bytes: Int64 = 1_000) -> PhotoAsset {
        Samples.asset(id: "00000000-0000-0000-0000-\(String(format: "%012d", number))/L0/001", byteSize: bytes)
    }

    private func library(
        _ store: FakePhotoStore, index: @escaping PhotosLibrary.IndexLoader = PhotosLibraryFacadeTests.noIndex
    ) -> PhotosLibrary {
        PhotosLibrary(store: store, loadIndex: index)
    }

    /// Plays a library change and waits until the refetch it causes has finished.
    private func change(_ store: FakePhotoStore, _ photos: PhotosLibrary) async {
        let before = store.videosCallCount
        store.emitChange()
        while store.videosCallCount == before { await Task.yield() }
        await photos.waitUntilIdle()
    }

    // MARK: - Authorization

    @Test func startDoesNotAskWhenAccessIsNotDetermined() async {
        let store = FakePhotoStore(assets: [asset(1)], authorization: .notDetermined)
        let photos = library(store)
        #expect(!photos.isAuthorizationKnown)
        await photos.start()
        #expect(photos.isAuthorizationKnown)
        #expect(photos.authorization == .notDetermined)
        #expect(photos.items.isEmpty)
        #expect(store.requestCount == 0)
        #expect(store.videosCallCount == 0)
    }

    @Test func requestingAccessLoadsWhenGranted() async {
        let store = FakePhotoStore(assets: [asset(1), asset(2)], authorization: .notDetermined)
        let photos = library(store)
        await photos.start()
        await photos.requestAccess()
        #expect(store.requestCount == 1)
        #expect(photos.authorization == .authorized)
        #expect(photos.items.count == 2)
        #expect(photos.hasLoaded)
    }

    @Test func limitedAccessLoadsToo() async {
        let store = FakePhotoStore(assets: [asset(1)], authorization: .notDetermined)
        store.authorizationOnRequest = .limited
        let photos = library(store)
        await photos.requestAccess()
        #expect(photos.authorization == .limited)
        #expect(photos.items.count == 1)
    }

    @Test(arguments: [PhotoAuthorization.denied, .restricted])
    func deniedAccessLoadsNothing(answer: PhotoAuthorization) async {
        let store = FakePhotoStore(assets: [asset(1)], authorization: .notDetermined)
        store.authorizationOnRequest = answer
        let photos = library(store)
        await photos.requestAccess()
        #expect(photos.authorization == answer)
        #expect(photos.items.isEmpty)
        #expect(!photos.hasLoaded)
        #expect(store.videosCallCount == 0)
        #expect(store.subscriberCount == 0)
    }

    @Test func accessGrantedInSettingsLoadsOnTheNextStart() async {
        let store = FakePhotoStore(assets: [asset(1)], authorization: .denied)
        let photos = library(store)
        await photos.start()
        #expect(photos.items.isEmpty)
        store.currentAuthorization = .authorized
        await photos.start()
        #expect(photos.authorization == .authorized)
        #expect(photos.items.count == 1)
        // Starting again doesn't open a second subscription.
        await photos.start()
        #expect(store.subscriberCount == 1)
    }

    // MARK: - First load

    @Test func firstLoadBuildsItemsWithStableIDs() async {
        let first = asset(1)
        let store = FakePhotoStore(assets: [first, asset(2)])
        let photos = library(store)
        #expect(photos.items.isEmpty)
        await photos.start()
        #expect(photos.items.count == 2)
        #expect(photos.items.first?.id == PhotoItemBuilder.itemID(for: first.id))
        #expect(photos.items.allSatisfy { $0.fileURL == nil })
        #expect(!photos.isScanning)
        #expect(photos.loadError == nil)
    }

    @Test func indexFillsFrameRateAndCodec() async {
        let one = asset(1)
        let uuid = PhotoItemBuilder.assetUUID(fromLocalIdentifier: one.id)
        let store = FakePhotoStore(assets: [one])
        let photos = library(store) {
            ([uuid: PhotoIndexEntry(fps: 59.94, codec: "hvc1", hdrType: 0)], .loaded(count: 1))
        }
        await photos.start()
        #expect(photos.indexStatus == .loaded(count: 1))
        #expect(photos.items.first?.frameRate == 59.94)
        #expect(photos.items.first?.inventory["video.codec"]?.value == "hvc1")
    }

    @Test func indexLookupIgnoresCase() async {
        let one = asset(1)
        let uuid = PhotoItemBuilder.assetUUID(fromLocalIdentifier: one.id).lowercased()
        let store = FakePhotoStore(assets: [one])
        let photos = library(store) { ([uuid.uppercased(): PhotoIndexEntry(fps: 30)], .loaded(count: 1)) }
        await photos.start()
        #expect(photos.items.first?.frameRate == 30)
    }

    @Test func withoutIndexAccessEverythingElseStillWorks() async {
        let store = FakePhotoStore(assets: [asset(1)])
        let photos = library(store)
        await photos.start()
        #expect(photos.indexStatus == .noAccess)
        #expect(photos.items.count == 1)
        #expect(photos.items.first?.frameRate == 0)
    }

    @Test func failedFetchIsReportedAndKeepsWhatWasShown() async {
        let store = FakePhotoStore(assets: [asset(1)])
        let photos = library(store)
        await photos.start()
        store.videosError = .notAuthorized
        await change(store, photos)
        #expect(photos.loadError != nil)
        #expect(photos.items.count == 1)
        store.videosError = nil
        await change(store, photos)
        #expect(photos.loadError == nil)
    }

    // MARK: - Changes

    @Test func aChangeRefetches() async {
        let store = FakePhotoStore(assets: [asset(1)])
        let photos = library(store)
        await photos.start()
        let revision = photos.revision
        store.assets = [asset(1), asset(2), asset(3)]
        await change(store, photos)
        #expect(photos.items.count == 3)
        #expect(photos.revision > revision)
    }

    @Test func changesDuringAFetchCoalesceIntoOneMore() async {
        let store = FakePhotoStore(assets: [asset(1)])
        let photos = library(store)
        await photos.start()
        #expect(store.videosCallCount == 1)

        let gate = Gate()
        store.beforeVideos = { await gate.wait() }
        store.assets = [asset(1), asset(2)]
        store.emitChange()
        // Wait until the refetch is in flight (holding at the gate).
        while store.videosCallCount < 2 { await Task.yield() }
        // Five more changes while it runs.
        store.assets = [asset(1), asset(2), asset(3)]
        for _ in 0..<5 {
            store.emitChange()
            await Task.yield()
        }
        #expect(store.videosCallCount == 2)

        store.beforeVideos = nil
        await gate.open()
        await photos.waitUntilIdle()
        // The held fetch plus exactly one more, which saw the latest library.
        #expect(store.videosCallCount == 3)
        #expect(photos.items.count == 3)
    }

    @Test func unchangedLibraryKeepsTheRevision() async {
        let store = FakePhotoStore(assets: [asset(1)])
        let photos = library(store)
        await photos.start()
        let revision = photos.revision
        await change(store, photos)
        #expect(photos.revision == revision)
    }

    @Test func stopEndsTheSubscription() async {
        let store = FakePhotoStore(assets: [asset(1)])
        let photos = library(store)
        await photos.start()
        #expect(store.subscriberCount == 1)
        photos.stop()
        await Task.yield()
        #expect(store.subscriberCount == 0)
    }

    @Test func reloadingTheIndexAppliesNewlyReadableFrameRates() async {
        let one = asset(1)
        let uuid = PhotoItemBuilder.assetUUID(fromLocalIdentifier: one.id)
        let store = FakePhotoStore(assets: [one])
        let answer = Locked<[String: PhotoIndexEntry]>([:])
        let photos = library(store) { (answer.value, answer.value.isEmpty ? .noAccess : .loaded(count: 1)) }
        await photos.start()
        #expect(photos.items.first?.frameRate == 0)
        answer.value = [uuid: PhotoIndexEntry(fps: 24)]
        await photos.reloadIndex()
        #expect(photos.indexStatus == .loaded(count: 1))
        #expect(photos.items.first?.frameRate == 24)
    }
}

import Synchronization

private final class Locked<Value: Sendable>: Sendable {
    private let state: Mutex<Value>

    init(_ value: Value) { state = Mutex(value) }

    var value: Value {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
