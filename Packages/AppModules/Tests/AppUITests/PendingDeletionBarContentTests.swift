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
            let text = PendingDeletionBarContent(count: 2, status: status).accessibilityLabel
            #expect(!text.localizedCaseInsensitiveContains("verified in recently deleted"))
            #expect(!text.localizedCaseInsensitiveContains("permanently"))
        }
    }
}
