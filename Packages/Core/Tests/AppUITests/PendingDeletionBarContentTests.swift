import Testing

@testable import AppUI

@Suite struct PendingDeletionBarContentTests {
    @Test func readySaysHowManyAndWhenICloudSpaceIsFreed() {
        let content = PendingDeletionBarContent(count: 12, status: .ready)

        #expect(content.title == "12 originals are ready to move to Recently Deleted")
        #expect(content.detail.contains("iCloud space is freed when Recently Deleted is emptied, or after 30 days."))
        #expect(content.buttonTitle == "Move Originals to Recently Deleted…")
        #expect(content.isDestructiveAction)
        #expect(!content.isWorking)
    }

    @Test func oneOriginalIsSingular() {
        #expect(
            PendingDeletionBarContent(count: 1, status: .ready).title
                == "1 original is ready to move to Recently Deleted")
        #expect(
            PendingDeletionBarContent(count: 1, status: .moved(savedBytes: 0)).title
                == "1 original moved to Recently Deleted")
    }

    @Test func aDeclinedConfirmationSaysTheOriginalsWereKept() {
        let content = PendingDeletionBarContent(count: 3, status: .declined)

        #expect(content.title == "Originals kept. You can move them to Recently Deleted later.")
        #expect(content.buttonTitle == PendingDeletionBarContent.actionTitle)
        #expect(content.isDestructiveAction)
    }

    @Test func waitingShowsNoButtonAndMentionsPhotosAsking() {
        let content = PendingDeletionBarContent(count: 3, status: .working)

        #expect(content.isWorking)
        #expect(content.buttonTitle == nil)
        #expect(content.detail == "Photos asks you to confirm.")
    }

    @Test func movedShowsTheSavedTotalAndAnUndestructiveDone() {
        let content = PendingDeletionBarContent(count: 5, status: .moved(savedBytes: 2_000_000_000))

        #expect(content.title == "5 originals moved to Recently Deleted")
        #expect(content.detail.hasPrefix("You've saved "))
        #expect(content.detail.contains("iCloud space is freed"))
        #expect(content.buttonTitle == "Done")
        #expect(!content.isDestructiveAction)
    }

    @Test func aFailureShowsTheReasonAndAllowsATryAgain() {
        let content = PendingDeletionBarContent(
            count: 2, status: .failed("Access to your Photos library isn't allowed."))

        #expect(content.title == "Couldn't move originals to Recently Deleted")
        #expect(content.detail == "Access to your Photos library isn't allowed.")
        #expect(content.buttonTitle == PendingDeletionBarContent.actionTitle)
    }

    @Test func theBarNeverClaimsACheckItCannotDo() {
        for status in [
            PendingDeletionBarContent.Status.ready, .declined, .working, .moved(savedBytes: 1), .failed("x"),
        ] {
            let content = PendingDeletionBarContent(count: 2, status: status)
            let text = content.title + " " + content.detail
            #expect(!text.localizedCaseInsensitiveContains("verified in recently deleted"))
            #expect(!text.localizedCaseInsensitiveContains("permanently"))
        }
    }

    @Test func keptOriginalsAreListedWithAReasonAndCanBeRemovedFromTheList() {
        let content = PendingDeletionBarContent(
            count: 0, status: .ready, heldCount: 2,
            heldMessages: ["Kept the original because it changed after shrinking"])

        #expect(content.title == "2 originals were kept in Photos")
        #expect(content.detail == "Kept the original because it changed after shrinking")
        #expect(content.offersRemove)
        #expect(!content.offersSettings)
        #expect(content.buttonTitle == nil)  // nothing left to move
        #expect(PendingDeletionBarContent.removeTitle == "Remove from List")
    }

    @Test func aLimitedAccessHoldOffersSettingsAndAnotherTry() {
        let content = PendingDeletionBarContent(
            count: 0, status: .ready, heldCount: 1,
            heldMessages: ["Can't see this original with limited Photos access"], heldCanRetry: true,
            heldNeedsSettings: true)

        #expect(content.title == "1 original was kept in Photos")
        #expect(content.offersSettings)
        #expect(PendingDeletionBarContent.settingsTitle == "Open System Settings…")
        #expect(content.buttonTitle == PendingDeletionBarContent.actionTitle)
    }

    @Test func heldOriginalsAreAddedBelowTheUsualTextWhenOthersAreReady() {
        let content = PendingDeletionBarContent(
            count: 3, status: .ready, heldCount: 1,
            heldMessages: ["Kept the original because the shrunk copy is no longer in your library"])

        #expect(content.title == "3 originals are ready to move to Recently Deleted")
        #expect(content.detail.hasSuffix("no longer in your library"))
        #expect(content.detail.contains("iCloud space is freed"))
    }

    @Test func countedActionTitleHandlesSingularPluralAndStatuses() {
        #expect(
            PendingDeletionBarContent(count: 1, status: .ready).countedActionTitle
                == "Move 1 Original to Recently Deleted…")
        #expect(
            PendingDeletionBarContent(count: 12, status: .ready).countedActionTitle
                == "Move 12 Originals to Recently Deleted…")
        #expect(
            PendingDeletionBarContent(count: 3, status: .declined).countedActionTitle
                == "Move 3 Originals to Recently Deleted…")
        #expect(
            PendingDeletionBarContent(count: 2, status: .failed("x")).countedActionTitle
                == "Move 2 Originals to Recently Deleted…")
        #expect(
            PendingDeletionBarContent(count: 0, status: .ready, heldCount: 1, heldCanRetry: true)
                .countedActionTitle == PendingDeletionBarContent.actionTitle)
        #expect(PendingDeletionBarContent(count: 0, status: .ready, heldCount: 1).countedActionTitle == nil)
        #expect(PendingDeletionBarContent(count: 3, status: .working).countedActionTitle == nil)
        #expect(PendingDeletionBarContent(count: 5, status: .moved(savedBytes: 100)).countedActionTitle == "Done")
    }
}
