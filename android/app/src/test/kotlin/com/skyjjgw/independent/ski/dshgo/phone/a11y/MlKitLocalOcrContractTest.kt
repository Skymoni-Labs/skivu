package com.skyjjgw.independent.ski.dshgo.phone.a11y

import org.junit.Assert.*
import org.junit.Test

/** Pure input/status checks, not a substitute for SDK Task/Bitmap lifecycle device tests. */
class MlKitLocalOcrContractTest {
    @Test fun copyBudgetCoversApprovedGeometryWithoutOverflowOrScaling() {
        assertTrue(MlKitLocalOcr.acceptsCopyDimensions(1440, 3200))
        assertTrue(MlKitLocalOcr.acceptsCopyDimensions(1080, 3240))
        assertTrue(MlKitLocalOcr.acceptsCopyDimensions(4096, 2048))
        assertFalse(MlKitLocalOcr.acceptsCopyDimensions(4096, 2049))
        assertFalse(MlKitLocalOcr.acceptsCopyDimensions(Int.MAX_VALUE, Int.MAX_VALUE))
        assertFalse(MlKitLocalOcr.acceptsCopyDimensions(0, 1600))
        assertFalse(MlKitLocalOcr.acceptsCopyDimensions(720, -1))
    }

    @Test fun disabledHasTheAgreedExplicitMessageAndIsNotNotRequested() {
        assertEquals("本机文字识别已关闭", LocalOcrBoundary.message(
            LocalOcrResult.Unavailable(LocalOcrResult.Reason.DISABLED)))
        assertNotEquals(LocalOcrBoundary.message(LocalOcrResult.Unavailable(LocalOcrResult.Reason.DISABLED)),
            LocalOcrBoundary.message(LocalOcrResult.Unavailable(LocalOcrResult.Reason.NOT_REQUESTED)))
    }
}
