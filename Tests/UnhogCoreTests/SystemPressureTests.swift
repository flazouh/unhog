import Foundation
import Testing
@testable import UnhogCore

@Suite("System memory pressure")
struct SystemPressureTests {
    private let installed: UInt64 = 25_769_803_776  // 24 GB
    private let gigabyte: UInt64 = 1_073_741_824

    @Test("A calm machine reports nothing")
    func calmMachineIsQuiet() {
        var detector = SystemPressureDetector()
        let start = Date()

        #expect(detector.evaluate(reading(at: start)) == nil)
        #expect(detector.evaluate(reading(at: start.addingTimeInterval(60))) == nil)
    }

    @Test("A deep hole that is still being dug is critical")
    func activeThrashingIsCritical() {
        var detector = SystemPressureDetector()
        let start = Date()

        _ = detector.evaluate(
            reading(at: start, swap: 10 * gigabyte, pageOuts: 0)
        )
        // A second reading supplies the page-out rate: still paging hard.
        let pressure = detector.evaluate(
            reading(
                at: start.addingTimeInterval(30),
                swap: 10 * gigabyte,
                pageOuts: 30_000
            )
        )

        #expect(pressure?.level == .critical)
        #expect(pressure?.pageOutsPerSecond == 1_000)
    }

    @Test("A deep hole nobody is digging is only elevated")
    func staleSwapIsNotCritical() {
        var detector = SystemPressureDetector()
        let start = Date()

        // Swap left over from an earlier spike: deep, but the machine is idle
        // now and feels fine, so it must not be reported as critical.
        _ = detector.evaluate(
            reading(at: start, swap: 10 * gigabyte, pageOuts: 5_000)
        )
        let pressure = detector.evaluate(
            reading(
                at: start.addingTimeInterval(30),
                swap: 10 * gigabyte,
                pageOuts: 5_000
            )
        )

        #expect(pressure?.level == .elevated)
        #expect(pressure?.pageOutsPerSecond == 0)
    }

    @Test("Pressure has to last before it is reported")
    func briefSpikesAreIgnored() {
        var detector = SystemPressureDetector(
            thresholds: SystemPressureThresholds(sustainedFor: 20)
        )
        let start = Date()

        #expect(
            detector.evaluate(
                reading(at: start, swap: 10 * gigabyte, pageOuts: 0)
            ) == nil
        )
        #expect(
            detector.evaluate(
                reading(
                    at: start.addingTimeInterval(5),
                    swap: 10 * gigabyte,
                    pageOuts: 1_000
                )
            ) == nil
        )
        #expect(
            detector.evaluate(
                reading(
                    at: start.addingTimeInterval(25),
                    swap: 10 * gigabyte,
                    pageOuts: 2_000
                )
            ) != nil
        )
    }

    @Test("Recovering clears the pressure and resets the clock")
    func recoveryClearsPressure() {
        var detector = SystemPressureDetector()
        let start = Date()

        _ = detector.evaluate(reading(at: start, swap: 10 * gigabyte))
        #expect(
            detector.evaluate(
                reading(at: start.addingTimeInterval(30), swap: 10 * gigabyte)
            ) != nil
        )

        // Swap drained: the machine is well again.
        #expect(
            detector.evaluate(
                reading(at: start.addingTimeInterval(60), swap: 0)
            ) == nil
        )

        // A fresh episode must serve its own sustain window, not inherit the
        // previous one.
        #expect(
            detector.evaluate(
                reading(at: start.addingTimeInterval(65), swap: 10 * gigabyte)
            ) == nil
        )
    }

    @Test("Compression alone counts, even with no swap")
    func compressionAloneIsPressure() {
        var detector = SystemPressureDetector()
        let start = Date()

        _ = detector.evaluate(
            reading(at: start, swap: 0, compressed: 8 * gigabyte)
        )
        let pressure = detector.evaluate(
            reading(
                at: start.addingTimeInterval(30),
                swap: 0,
                compressed: 8 * gigabyte
            )
        )

        #expect(pressure != nil)
    }

    @Test("The machine that started all this reads as pressured")
    func realWorldReadingIsPressured() {
        // Measured on the affected Mac while it was thrashing, at a moment when
        // kern.memorystatus_vm_pressure_level still claimed to be normal.
        var detector = SystemPressureDetector()
        let start = Date()
        let observed = SystemMemoryReading(
            installedBytes: 25_769_803_776,
            freeBytes: 36_038 * 16_384,
            compressedBytes: 331_210 * 16_384,
            swapUsedBytes: 9_862 * 1_048_576,
            swapTotalBytes: 11_264 * 1_048_576,
            cumulativePageOuts: 751_993,
            takenAt: start
        )

        _ = detector.evaluate(observed)
        let later = SystemMemoryReading(
            installedBytes: observed.installedBytes,
            freeBytes: observed.freeBytes,
            compressedBytes: observed.compressedBytes,
            swapUsedBytes: observed.swapUsedBytes,
            swapTotalBytes: observed.swapTotalBytes,
            cumulativePageOuts: observed.cumulativePageOuts + 20_000,
            takenAt: start.addingTimeInterval(30)
        )

        let pressure = detector.evaluate(later)
        #expect(pressure?.level == .critical)
        #expect(pressure?.detail.contains("swap") == true)
    }

    @Test("Sampling the real machine returns plausible statistics")
    func samplerReadsTheMachine() throws {
        let reading = try #require(SystemMemorySampler().sample(at: Date()))

        #expect(reading.installedBytes > 0)
        #expect(reading.freeBytes <= reading.installedBytes)
        #expect(reading.compressedBytes <= reading.installedBytes)
        #expect(reading.swapUsedBytes <= reading.swapTotalBytes)
        // A page count multiplied by a wrong page size shows up here as a
        // wildly implausible total rather than a subtly wrong one.
        #expect(reading.compressedBytes + reading.freeBytes <= reading.installedBytes * 2)
    }

    private func reading(
        at date: Date,
        swap: UInt64 = 0,
        compressed: UInt64 = 0,
        pageOuts: UInt64 = 0
    ) -> SystemMemoryReading {
        SystemMemoryReading(
            installedBytes: installed,
            freeBytes: 8 * gigabyte,
            compressedBytes: compressed,
            swapUsedBytes: swap,
            swapTotalBytes: 11 * gigabyte,
            cumulativePageOuts: pageOuts,
            takenAt: date
        )
    }
}
