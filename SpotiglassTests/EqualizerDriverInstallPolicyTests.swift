import XCTest

@testable import Spotiglass

final class EqualizerDriverInstallPolicyTests: XCTestCase {
    private let firstRelease = EqualizerDriverVersion(shortVersion: "0.1.0", build: "1")!

    func testDriverVersionsCompareReleaseBeforeBuild() {
        let rebuilt = EqualizerDriverVersion(shortVersion: "0.1.0", build: "2")!
        let newerRelease = EqualizerDriverVersion(shortVersion: "0.2.0", build: "1")!

        XCTAssertLessThan(firstRelease, rebuilt)
        XCTAssertLessThan(rebuilt, newerRelease)
        XCTAssertEqual(firstRelease.description, "0.1 (1)")
        XCTAssertEqual(
            EqualizerDriverVersion(shortVersion: "0.1", build: "001"),
            firstRelease
        )
    }

    func testInvalidDriverVersionsAreRejected() {
        XCTAssertNil(EqualizerDriverVersion(shortVersion: "", build: "1"))
        XCTAssertNil(EqualizerDriverVersion(shortVersion: "0.1.x", build: "1"))
        XCTAssertNil(EqualizerDriverVersion(shortVersion: "0.1.0", build: ""))
        XCTAssertNil(EqualizerDriverVersion(shortVersion: "0.1.0", build: "1.2-beta"))
    }

    func testInstallDecisionCoversMissingRepairAndStaleBundles() {
        let missingDecision = EqualizerDriverInstallPolicy.decision(
            bundled: firstRelease,
            installed: .missing
        )
        XCTAssertEqual(missingDecision, .install(reason: .missing))
        XCTAssertTrue(missingDecision.shouldInstall)
        XCTAssertEqual(
            EqualizerDriverInstallPolicy.decision(
                bundled: firstRelease,
                installed: .unreadable
            ),
            .install(reason: .repair)
        )

        let oldDriver = EqualizerDriverVersion(shortVersion: "0.0.9", build: "8")!
        XCTAssertEqual(
            EqualizerDriverInstallPolicy.decision(
                bundled: firstRelease,
                installed: .version(oldDriver)
            ),
            .install(reason: .stale)
        )
    }

    func testInstallDecisionSkipsCurrentOrNewerBundle() {
        XCTAssertEqual(
            EqualizerDriverInstallPolicy.decision(
                bundled: firstRelease,
                installed: .version(firstRelease)
            ),
            .alreadyCurrent
        )

        let newerDriver = EqualizerDriverVersion(shortVersion: "0.1.0", build: "2")!
        let newerDecision = EqualizerDriverInstallPolicy.decision(
            bundled: firstRelease,
            installed: .version(newerDriver)
        )
        XCTAssertEqual(newerDecision, .alreadyCurrent)
        XCTAssertFalse(newerDecision.shouldInstall)
    }

    func testInstallErrorMappingKeepsDiagnosticsOutOfTheUserMessage() {
        let error = EqualizerDriverInstallError.helperOperationFailed(
            status: 74,
            message: "copyfile failed"
        )
        let mapped = EqualizerDriverInstallErrorMapper.map(error)

        XCTAssertEqual(
            mapped.diagnosticDetails,
            "Spotiglass EQ privileged helper failed (status 74): copyfile failed"
        )
        XCTAssertFalse(mapped.isUserVisible)
        XCTAssertNil(mapped.userFacingDescription)
    }

    func testEveryHelperFailureHasDiagnosticMapping() {
        let errors: [EqualizerDriverInstallError] = [
            .registrationFailed(status: 1),
            .unregistrationFailed(status: 2),
            .helperUnavailable(message: "not running"),
            .helperRejected(status: 64, message: "invalid path"),
            .helperOperationFailed(status: 74, message: "copy failed"),
            .invalidReply,
            .invalidRequest,
        ]

        for error in errors {
            let mapped = EqualizerDriverInstallErrorMapper.map(error)
            XCTAssertEqual(mapped.diagnosticDetails, error.diagnosticDetails)
            XCTAssertFalse(mapped.isUserVisible)
            XCTAssertNil(mapped.userFacingDescription)
        }
    }

    func testCodeSigningRequirementsPinTeamOrExplicitLocalCertificate() {
        XCTAssertEqual(
            EqualizerPrivilegedHelperIdentity.clientRequirement,
            "((anchor apple generic and certificate leaf[subject.OU] = \"BHAF4L4726\") or certificate leaf[subject.CN] = \"Spotiglass Local Dev\") and identifier \"com.isaaclins.spotiglass\""
        )
        XCTAssertEqual(
            EqualizerPrivilegedHelperIdentity.helperRequirement,
            "((anchor apple generic and certificate leaf[subject.OU] = \"BHAF4L4726\") or certificate leaf[subject.CN] = \"Spotiglass Local Dev\") and identifier \"com.isaaclins.spotiglass.eqprivilegedhelper\""
        )
        XCTAssertEqual(
            EqualizerPrivilegedHelperIdentity.driverRequirement,
            "((anchor apple generic and certificate leaf[subject.OU] = \"BHAF4L4726\") or certificate leaf[subject.CN] = \"Spotiglass Local Dev\") and identifier \"com.isaaclins.spotiglass.eqdriver\""
        )
    }

    func testDriverLifecycleErrorsHaveNoUserFacingDescription() {
        let errors: [EqualizerHALPluginError] = [
            .embeddedDriverMissing,
            .embeddedDriverMetadataMissing,
            .driverNotLoadedYet(installedPath: "/Library/Audio/Plug-Ins/HAL/SpotiglassEQDriver.driver"),
            .driverInstallationFailed(diagnostic: "helper unavailable"),
        ]

        for error in errors {
            XCTAssertFalse(error.isUserVisible)
            XCTAssertNil(error.userFacingDescription)
            XCTAssertNotNil(error.diagnosticDetails)
        }
    }
}
