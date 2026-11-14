package com.skyjjgw.independent.ski.dshgo.phone.background

import org.junit.Assert.*
import org.junit.Test

/** Pure selection/scan-order contract; Android node traversal and image admission need device validation. */
class BackgroundWindowSelectionTest {
    private val target = "test.target"

    @Test fun aSingleMatchingApplicationWindowOwnsTheOnlyScanSlot() {
        assertEquals(BackgroundTree.WindowSelection(0, listOf(0)), BackgroundTree.selectApplicationWindow(listOf(target), target))
    }

    @Test fun aMissingRootBeforeTheTargetStillRequiresAPrivacyScanSlot() {
        assertEquals(BackgroundTree.WindowSelection(1, listOf(1, 0)), BackgroundTree.selectApplicationWindow(listOf(null, target), target))
    }

    @Test fun aForeignApplicationBeforeTheTargetIsScannedAfterTheElementOwner() {
        assertEquals(BackgroundTree.WindowSelection(1, listOf(1, 0)), BackgroundTree.selectApplicationWindow(listOf("test.caption", target), target))
    }

    @Test fun everyAdditionalApplicationRootNeedsScanningRegardlessOfPackage() {
        for (other in listOf(null, "test.caption", target)) {
            assertEquals(BackgroundTree.WindowSelection(0, listOf(0, 1)), BackgroundTree.selectApplicationWindow(listOf(target, other), target))
        }
    }

    @Test fun theFirstExactPackageMatchOwnsElementsAndEveryOtherRootIsVisitedOnce() {
        val packages = listOf("test.target.extra", null, target, target)
        val selected = BackgroundTree.selectApplicationWindow(packages, target)!!
        assertEquals(2, selected.index)
        assertEquals(listOf(2, 0, 1, 3), selected.scanOrder)
        assertEquals(packages.indices.toList(), selected.scanOrder.sorted())
    }

    @Test fun noMatchingRootNeverSelectsAnotherPackage() {
        for (packages in listOf(emptyList(), listOf(null), listOf("test.caption"), listOf(null, "test.caption"))) {
            assertNull(BackgroundTree.selectApplicationWindow(packages, target))
        }
    }
}
