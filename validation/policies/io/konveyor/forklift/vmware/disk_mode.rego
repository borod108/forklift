package io.konveyor.forklift.vmware
import future.keywords.in

independent_disk {
    some i
    input.disks[i].mode in ["independent_persistent", "independent_nonpersistent"]
}

concerns[flag] {
    independent_disk
    flag := {
        "id": "vmware.disk_mode.independent",
        "category": "Warning",
        "label": "Independent disk detected",
        "assessment": "Independent disks cannot be transferred using VDDK. If copy-offload (XCOPY) is enabled in the migration plan, independent disks can be migrated. Otherwise, the disks must be changed to 'Dependent' mode in VMware before migration."
    }
}
