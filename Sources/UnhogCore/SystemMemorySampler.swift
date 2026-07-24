import Darwin
import Foundation

public protocol SystemMemorySampling: Sendable {
    func sample(at date: Date) -> SystemMemoryReading?
}

/// Reads whole-machine memory statistics straight from the kernel.
///
/// `pageouts` is the activity signal rather than `swapouts`: measured on a
/// thrashing Mac over ten seconds, pageouts advanced by 337 while swapouts did
/// not move at all, so keying off swapouts would have reported an idle machine
/// while it was visibly struggling.
public struct SystemMemorySampler: SystemMemorySampling, Sendable {
    public init() {}

    public func sample(at date: Date = Date()) -> SystemMemoryReading? {
        guard let statistics = virtualMemoryStatistics() else { return nil }

        let pageSize = pageSize()
        let swap = swapUsage()

        return SystemMemoryReading(
            installedBytes: ProcessInfo.processInfo.physicalMemory,
            freeBytes: UInt64(statistics.free_count) * pageSize,
            compressedBytes: UInt64(statistics.compressor_page_count) * pageSize,
            swapUsedBytes: swap?.xsu_used ?? 0,
            swapTotalBytes: swap?.xsu_total ?? 0,
            cumulativePageOuts: statistics.pageouts,
            takenAt: date
        )
    }

    private func virtualMemoryStatistics() -> vm_statistics64? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride
                / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    rebound,
                    &count
                )
            }
        }

        return result == KERN_SUCCESS ? statistics : nil
    }

    private func swapUsage() -> xsw_usage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return nil
        }
        return usage
    }

    private func pageSize() -> UInt64 {
        var size: vm_size_t = 0
        guard host_page_size(mach_host_self(), &size) == KERN_SUCCESS,
            size > 0
        else {
            return UInt64(max(4096, sysconf(_SC_PAGESIZE)))
        }
        return UInt64(size)
    }
}
