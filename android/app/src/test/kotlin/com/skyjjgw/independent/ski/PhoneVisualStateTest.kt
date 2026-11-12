package com.skyjjgw.independent.ski

import org.junit.Assert.*
import org.junit.Test
import java.awt.BasicStroke
import java.awt.Color
import java.awt.Font
import java.awt.RenderingHints
import java.awt.image.BufferedImage
import javax.imageio.ImageIO

class PhoneVisualStateTest {
    private fun image(size:Int=128,paint:(java.awt.Graphics2D)->Unit):PhoneVisualState.Raster {
        val bitmap=BufferedImage(size,size,BufferedImage.TYPE_INT_ARGB)
        val canvas=bitmap.createGraphics()
        canvas.color=Color.WHITE;canvas.fillRect(0,0,size,size)
        canvas.setRenderingHint(RenderingHints.KEY_ANTIALIASING,RenderingHints.VALUE_ANTIALIAS_ON)
        canvas.stroke=BasicStroke(2f);canvas.color=Color(0,155,255)
        paint(canvas);canvas.dispose()
        return PhoneVisualState.Raster(size,size,bitmap.getRGB(0,0,size,size,null,0,size))
    }

    @Test fun standardRadioEmptyDotAndSolidAreDistinct() {
        val empty=image{it.drawOval(16,16,96,96)}
        val dot=image{it.drawOval(16,16,96,96);it.fillOval(44,44,40,40)}
        val solid=image{it.fillOval(16,16,96,96)}
        assertFalse(PhoneVisualState.detect(empty).single().checked)
        assertTrue(PhoneVisualState.detect(dot).single().checked)
        assertTrue(PhoneVisualState.detect(solid).single().checked)
        assertEquals("radio",PhoneVisualState.detect(dot).single().kind)
    }

    private fun check(canvas:java.awt.Graphics2D) {
        canvas.stroke=BasicStroke(6f,BasicStroke.CAP_ROUND,BasicStroke.JOIN_ROUND)
        canvas.drawLine(35,64,54,83);canvas.drawLine(54,83,93,43)
    }

    @Test fun checkboxRequiresCompleteBoxAndRecognizedCheck() {
        val empty=image{it.drawRect(16,16,96,96)}
        val checked=image{it.drawRect(16,16,96,96);check(it)}
        val filled=image{it.fillRect(16,16,96,96);it.color=Color.WHITE;check(it)}
        assertFalse(PhoneVisualState.detect(empty).single().checked)
        assertTrue(PhoneVisualState.detect(checked).single().checked)
        assertTrue(PhoneVisualState.detect(filled).single().checked)
        assertEquals("checkbox",PhoneVisualState.detect(checked).single().kind)
    }

    @Test fun arbitraryInteriorChangesAndUnknownSymbolsProvideNoState() {
        for (paint in listOf<(java.awt.Graphics2D)->Unit>(
            {it.fillRect(60,59,9,9)},
            {it.stroke=BasicStroke(5f);it.drawLine(35,35,93,93);it.drawLine(35,93,93,35)},
            {it.stroke=BasicStroke(6f);it.drawLine(40,64,88,64)},
        )) {
            assertTrue(PhoneVisualState.detect(image{it.drawRect(16,16,96,96);paint(it)}).isEmpty())
        }
    }

    @Test fun lettersNeedAnExplicitSameFrameOcrGlyphAndCannotHideSolidFill() {
        val glyph=PhoneVisualState.Box(50,45,78,81)
        val empty=image{it.drawOval(16,16,96,96);it.font=Font("Dialog",Font.PLAIN,32);it.drawString("A",52,77)}
        assertFalse(PhoneVisualState.detect(empty).single().checked)
        assertFalse(PhoneVisualState.detect(empty,listOf(glyph)).single().checked)
        val filled=image{it.fillOval(16,16,96,96);it.color=Color.WHITE;it.font=Font("Dialog",Font.PLAIN,32);it.drawString("A",52,77)}
        assertTrue(PhoneVisualState.detect(filled,listOf(glyph)).single().checked)
    }

    @Test fun optionLettersAndBoldStrokesNeverBecomeSelectedDotsOrChecks() {
        for(letter in 'A'..'H')for(style in listOf(Font.PLAIN,Font.BOLD))for(size in listOf(20,32,44)) {
            var glyph:PhoneVisualState.Box?=null
            val empty=image { canvas ->
                canvas.drawOval(16,16,96,96)
                canvas.font=Font("Dialog",style,size)
                val metrics=canvas.fontMetrics
                val left=(128-metrics.charWidth(letter))/2
                val baseline=(128-metrics.height)/2+metrics.ascent
                canvas.drawString(letter.toString(),left,baseline)
                glyph=PhoneVisualState.Box(left,baseline-metrics.ascent,left+metrics.charWidth(letter),baseline+metrics.descent)
            }
            val marks=PhoneVisualState.detect(empty,listOf(glyph!!))
            assertEquals("letter $letter style $style size $size",1,marks.size)
            assertFalse("letter $letter style $style size $size",marks.single().checked)
        }
    }

    @Test fun lowContrastClippingAndPrivacyMaskReturnUnknown() {
        assertTrue(PhoneVisualState.detect(image{it.color=Color(235,235,235);it.drawOval(16,16,96,96)}).isEmpty())
        assertTrue(PhoneVisualState.detect(image{it.drawOval(-12,16,96,96)}).isEmpty())
        val transparent=image{it.drawOval(16,16,96,96)}.let { raster ->
            raster.pixels[0]=0; raster
        }
        assertTrue(PhoneVisualState.detect(transparent).isEmpty())
    }

    @Test fun isolatedCheckWithoutControlOutlineIsUnknown() {
        assertTrue(PhoneVisualState.detect(image{check(it)}).isEmpty())
    }

    @Test fun unsupportedCenterGlyphsNeverBecomeUncheckedLetterOptions() {
        for(symbol in listOf("X","V","?","+","-","Z","8")) {
            val mark=image{it.drawOval(16,16,96,96);it.font=Font("Dialog",Font.PLAIN,32);it.drawString(symbol,52,77)}
            assertTrue("unsupported glyph $symbol",PhoneVisualState.detect(mark).isEmpty())
        }
    }

    @Test fun actualCanvasFixtureLettersDoNotRequireAnotherOcrPass() {
        for(letter in listOf("a","b")) {
            val input=javaClass.getResourceAsStream("/phone-visual-state/canvas-empty-$letter.png")!!
            val bitmap=input.use{ImageIO.read(it)}
            val raster=PhoneVisualState.Raster(bitmap.width,bitmap.height,bitmap.getRGB(0,0,bitmap.width,bitmap.height,null,0,bitmap.width))
            assertFalse("actual canvas $letter",PhoneVisualState.detect(raster).single().checked)
        }
    }

    @Test fun actualLearningTongEmptyLetterRadioIsUnchecked() {
        val input=javaClass.getResourceAsStream("/phone-visual-state/empty-letter-radio.png")!!
        val bitmap=input.use{ImageIO.read(it)}
        val raster=PhoneVisualState.Raster(bitmap.width,bitmap.height,bitmap.getRGB(0,0,bitmap.width,bitmap.height,null,0,bitmap.width))
        val mark=PhoneVisualState.detect(raster,listOf(PhoneVisualState.Box(48,45,75,78))).single()
        assertEquals("radio",mark.kind)
        assertFalse(mark.checked)
        assertTrue(mark.confidence>=0.9)
    }
}
