import XCTest
@testable import OpenWebUIKit

/// The app lock's decisions, with no LocalAuthentication in the way.
///
/// What cannot be tried without a device (the Face ID sheet, the app switcher
/// snapshot) is the glue in `App/`; what can go wrong in the logic is pinned
/// here: a lock that fires on Control Center would be unusable, one that
/// survives a trip to the background would be decoration, and one that engages
/// with the setting off would lock people out of an app they never asked to lock.
final class AppLockPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// An enabled lock that has been opened and is in use.
    private func unlockedInUse(grace: TimeInterval = 0) -> AppLockPolicy {
        var p = AppLockPolicy(enabled: true, gracePeriod: grace)
        p.sceneChanged(to: .active, at: at(0))
        p.didUnlock(at: at(1))
        return p
    }

    // MARK: - Off by default

    func testADisabledLockNeverEngagesNorCoversAnything() {
        var p = AppLockPolicy(enabled: false)
        XCTAssertFalse(p.isLocked)
        for phase in [AppLockPolicy.Phase.active, .inactive, .background, .inactive, .active] {
            p.sceneChanged(to: phase, at: at(5))
            XCTAssertFalse(p.isLocked, "locked in \(phase) with the setting off")
            XCTAssertFalse(p.coverVisible, "cover up in \(phase) with the setting off")
            XCTAssertFalse(p.shouldPrompt)
        }
    }

    // MARK: - Cold launch

    func testAnEnabledLockStartsLockedAndPromptsOnceTheSceneIsActive() {
        var p = AppLockPolicy(enabled: true)
        XCTAssertTrue(p.isLocked)
        XCTAssertTrue(p.coverVisible)
        XCTAssertFalse(p.shouldPrompt, "the sheet cannot be presented before the scene is active")
        p.sceneChanged(to: .active, at: at(0))
        XCTAssertTrue(p.shouldPrompt)
        XCTAssertTrue(p.isLocked)
    }

    func testUnlockingOpensTheAppAndStopsPrompting() {
        var p = AppLockPolicy(enabled: true)
        p.sceneChanged(to: .active, at: at(0))
        p.didUnlock(at: at(2))
        XCTAssertFalse(p.isLocked)
        XCTAssertFalse(p.coverVisible)
        XCTAssertFalse(p.shouldPrompt)
        XCTAssertEqual(p.lastUnlock, at(2))
    }

    // MARK: - Brief interruptions

    func testControlCenterAndTheFaceIDSheetCoverTheScreenButDoNotLock() {
        var p = unlockedInUse()
        p.sceneChanged(to: .inactive, at: at(10))
        XCTAssertFalse(p.isLocked)
        XCTAssertTrue(p.coverVisible, "the app switcher snapshot is taken from .inactive")
        p.sceneChanged(to: .active, at: at(11))
        XCTAssertFalse(p.isLocked, "a swipe to Control Center must not ask for Face ID")
        XCTAssertFalse(p.coverVisible)
    }

    func testTheSheetOfTheAuthenticationItselfDoesNotRelock() {
        var p = AppLockPolicy(enabled: true)
        p.sceneChanged(to: .active, at: at(0))
        p.beginAuthentication()
        p.sceneChanged(to: .inactive, at: at(0.1))   // Face ID sheet takes the foreground
        XCTAssertTrue(p.isLocked)
        XCTAssertFalse(p.shouldPrompt, "already prompting")
        p.sceneChanged(to: .active, at: at(1))
        p.endAuthentication()
        XCTAssertTrue(p.shouldPrompt, "a cancelled sheet leaves the lock up, ready to ask again")
    }

    func testTheCoverWhileEnablingDoesNotFlashOverSettings() {
        // Enabling runs a Face ID prompt over Settings: the scene goes inactive
        // with the lock still off-duty, and the cover must not blank the screen.
        var p = unlockedInUse()
        p.beginAuthentication()
        p.sceneChanged(to: .inactive, at: at(3))
        XCTAssertFalse(p.coverVisible)
        p.sceneChanged(to: .active, at: at(4))
        p.endAuthentication()
        XCTAssertFalse(p.isLocked)
    }

    // MARK: - Background

    func testGoingToTheBackgroundLocksAtOnceWithTheDefaultGrace() {
        var p = unlockedInUse()
        XCTAssertEqual(p.gracePeriod, 0)
        p.sceneChanged(to: .inactive, at: at(10))
        p.sceneChanged(to: .background, at: at(10.1))
        XCTAssertTrue(p.isLocked, "locked while still away, not on the way back")
        p.sceneChanged(to: .inactive, at: at(60))
        XCTAssertTrue(p.coverVisible)
        p.sceneChanged(to: .active, at: at(60.1))
        XCTAssertTrue(p.isLocked)
        XCTAssertTrue(p.shouldPrompt)
    }

    func testAnUnlockThatArrivesAfterTheAppLeftIsIgnored() {
        var p = AppLockPolicy(enabled: true)
        p.sceneChanged(to: .active, at: at(0))
        p.beginAuthentication()
        p.sceneChanged(to: .background, at: at(1))
        p.didUnlock(at: at(1.2))      // the success callback loses the race
        XCTAssertTrue(p.isLocked)
        XCTAssertNil(p.lastUnlock)
    }

    // MARK: - Grace period

    func testReturningWithinTheGraceKeepsTheAppOpen() {
        var p = unlockedInUse(grace: 30)
        p.sceneChanged(to: .inactive, at: at(10))
        p.sceneChanged(to: .background, at: at(10.1))
        XCTAssertFalse(p.isLocked)
        XCTAssertTrue(p.coverVisible, "away from the foreground the snapshot is still hidden")
        p.sceneChanged(to: .inactive, at: at(25))
        p.sceneChanged(to: .active, at: at(25.1))
        XCTAssertFalse(p.isLocked)
        XCTAssertFalse(p.coverVisible)
    }

    func testReturningAfterTheGraceLocks() {
        var p = unlockedInUse(grace: 30)
        p.sceneChanged(to: .background, at: at(10))
        p.sceneChanged(to: .inactive, at: at(41))
        p.sceneChanged(to: .active, at: at(41.1))
        XCTAssertTrue(p.isLocked)
    }

    func testReturningExactlyAtTheGraceLocks() {
        var p = unlockedInUse(grace: 30)
        p.sceneChanged(to: .background, at: at(10))
        p.sceneChanged(to: .active, at: at(40))
        XCTAssertTrue(p.isLocked)
    }

    func testAClockSetBackwardsLocksRatherThanTrustingTheDifference() {
        var p = unlockedInUse(grace: 30)
        p.sceneChanged(to: .background, at: at(100))
        p.sceneChanged(to: .active, at: at(50))
        XCTAssertTrue(p.isLocked)
    }

    func testANegativeGraceIsTreatedAsNone() {
        var p = unlockedInUse(grace: -5)
        XCTAssertEqual(p.gracePeriod, 0)
        p.sceneChanged(to: .background, at: at(10))
        XCTAssertTrue(p.isLocked)
    }

    func testTheGraceIsMeasuredFromEachTripNotFromTheFirst() {
        var p = unlockedInUse(grace: 30)
        p.sceneChanged(to: .background, at: at(10))
        p.sceneChanged(to: .active, at: at(20))
        XCTAssertFalse(p.isLocked)
        p.sceneChanged(to: .background, at: at(500))   // long after the first trip
        p.sceneChanged(to: .active, at: at(510))
        XCTAssertFalse(p.isLocked, "10 s away, however long the session")
    }

    // MARK: - The setting

    func testEnablingFromSettingsDoesNotLockTheSessionThatJustAuthenticated() {
        var p = AppLockPolicy(enabled: false)
        p.sceneChanged(to: .active, at: at(0))
        p.setEnabled(true, authenticatedAt: at(5))
        XCTAssertTrue(p.isEnabled)
        XCTAssertFalse(p.isLocked)
        XCTAssertEqual(p.lastUnlock, at(5))
        p.sceneChanged(to: .background, at: at(6))
        XCTAssertTrue(p.isLocked, "and from now on it guards the app")
    }

    func testDisablingOpensAnythingLockedAndStopsCovering() {
        var p = AppLockPolicy(enabled: true)
        p.sceneChanged(to: .active, at: at(0))
        p.setEnabled(false, authenticatedAt: at(1))
        XCTAssertFalse(p.isEnabled)
        XCTAssertFalse(p.isLocked)
        p.sceneChanged(to: .background, at: at(2))
        p.sceneChanged(to: .active, at: at(3))
        XCTAssertFalse(p.isLocked)
        XCTAssertFalse(p.coverVisible)
    }

    /// Review finding #21: the confirmation sheet can lose the race with the
    /// scene. A success that lands after the app went to the background used to
    /// leave the lock enabled but open, with no absence recorded, so the next
    /// return was not locked and the snapshot taken meanwhile was uncovered.
    func testEnablingThatFinishesInTheBackgroundLeavesTheAppLocked() {
        var p = AppLockPolicy(enabled: false)
        p.sceneChanged(to: .background, at: at(0))
        p.setEnabled(true, authenticatedAt: at(1))
        XCTAssertTrue(p.isEnabled)
        XCTAssertTrue(p.isLocked, "enabled while away must not leave the app open")
        XCTAssertTrue(p.coverVisible)
        p.sceneChanged(to: .active, at: at(2))
        XCTAssertTrue(p.isLocked, "coming back asks for the unlock")
        XCTAssertTrue(p.shouldPrompt)
    }

    func testEnablingInTheBackgroundStaysLockedEvenWithAGrace() {
        var p = AppLockPolicy(enabled: false, gracePeriod: 60)
        p.sceneChanged(to: .background, at: at(0))
        p.setEnabled(true, authenticatedAt: at(1))
        p.sceneChanged(to: .active, at: at(2))
        XCTAssertTrue(p.isLocked)
    }

    func testEnablingWhileActiveStillKeepsTheSessionOpen() {
        var p = AppLockPolicy(enabled: false)
        p.sceneChanged(to: .inactive, at: at(0))      // the Face ID sheet itself
        p.setEnabled(true, authenticatedAt: at(1))
        XCTAssertFalse(p.isLocked)
    }

    // MARK: - Nobody is locked out (review finding #19)

    /// The passcode was removed after the lock was turned on: every attempt ends
    /// `.unavailable` and Settings, where the switch lives, is behind the cover.
    func testUnavailableAuthenticationTurnsTheLockOffSoTheAppOpens() {
        var p = AppLockPolicy(enabled: true)
        p.sceneChanged(to: .active, at: at(0))
        p.beginAuthentication()
        p.authenticationFinished(.unavailable, at: at(1))
        p.endAuthentication()
        XCTAssertFalse(p.isEnabled)
        XCTAssertFalse(p.isLocked)
        XCTAssertFalse(p.coverVisible)
        XCTAssertFalse(p.shouldPrompt)
        p.sceneChanged(to: .background, at: at(2))
        p.sceneChanged(to: .active, at: at(3))
        XCTAssertFalse(p.coverVisible, "and it stays off")
    }

    func testAFailedAttemptKeepsTheLockAndRemembersWhy() {
        var p = AppLockPolicy(enabled: true)
        p.sceneChanged(to: .active, at: at(0))
        p.beginAuthentication()
        p.authenticationFinished(.failed, at: at(1))
        p.endAuthentication()
        XCTAssertTrue(p.isEnabled)
        XCTAssertTrue(p.isLocked)
        XCTAssertEqual(p.lastFailure, .failed, "the cover shows the reason")
        XCTAssertTrue(p.shouldPrompt, "and the button works again")
    }

    func testCancellingIsNotAFailureAndTheNextAttemptClearsTheReason() {
        var p = AppLockPolicy(enabled: true)
        p.sceneChanged(to: .active, at: at(0))
        p.authenticationFinished(.failed, at: at(1))
        XCTAssertEqual(p.lastFailure, .failed)
        p.beginAuthentication()
        XCTAssertNil(p.lastFailure, "a new attempt starts without the old message")
        p.authenticationFinished(.cancelled, at: at(2))
        p.endAuthentication()
        XCTAssertNil(p.lastFailure)
        XCTAssertTrue(p.isLocked)
    }

    func testSuccessThroughTheOutcomeUnlocksAndClearsTheReason() {
        var p = AppLockPolicy(enabled: true)
        p.sceneChanged(to: .active, at: at(0))
        p.authenticationFinished(.failed, at: at(1))
        p.authenticationFinished(.success, at: at(2))
        XCTAssertFalse(p.isLocked)
        XCTAssertNil(p.lastFailure)
        XCTAssertEqual(p.lastUnlock, at(2))
    }

    func testUnavailableWhileTheLockIsAlreadyOffChangesNothing() {
        var p = AppLockPolicy(enabled: false)
        p.sceneChanged(to: .active, at: at(0))
        p.authenticationFinished(.unavailable, at: at(1))
        XCTAssertFalse(p.isEnabled)
        XCTAssertNil(p.lastFailure)
    }

    // MARK: - One cover per scene (review finding #20)

    /// iPad: scene B in Stage Manager / Slide Over goes away while A stays
    /// active. The aggregate phase stays `.active`, but B's own snapshot must
    /// still be blank.
    func testASceneThatIsNotActiveIsCoveredEvenWhileAnotherOneIs() {
        var p = unlockedInUse()
        XCTAssertEqual(p.phase, .active)               // the aggregate: A is active
        XCTAssertFalse(p.coverVisible)
        XCTAssertFalse(p.coverVisible(forScene: .active), "scene A stays open")
        XCTAssertTrue(p.coverVisible(forScene: .inactive), "scene B's switcher snapshot")
        XCTAssertTrue(p.coverVisible(forScene: .background))
        p.sceneChanged(to: .inactive, at: at(5))
        XCTAssertTrue(p.coverVisible(forScene: .inactive))
    }

    func testThePerSceneCoverFollowsTheSameRulesAsTheAggregate() {
        var off = AppLockPolicy(enabled: false)
        off.sceneChanged(to: .active, at: at(0))
        XCTAssertFalse(off.coverVisible(forScene: .background), "nothing is covered with the setting off")

        var locked = AppLockPolicy(enabled: true)
        locked.sceneChanged(to: .active, at: at(0))
        XCTAssertTrue(locked.coverVisible(forScene: .active), "locked covers every scene")

        var authing = unlockedInUse()
        authing.beginAuthentication()
        XCTAssertFalse(authing.coverVisible(forScene: .inactive),
                       "the system sheet is the reason, not a reason to blink")
    }

    func testTheAggregateCoverAgreesWithThePerSceneOneForTheAggregatePhase() {
        for phase in [AppLockPolicy.Phase.active, .inactive, .background] {
            var p = unlockedInUse()
            p.sceneChanged(to: phase, at: at(9))
            XCTAssertEqual(p.coverVisible, p.coverVisible(forScene: p.phase), "\(phase)")
        }
    }
}
