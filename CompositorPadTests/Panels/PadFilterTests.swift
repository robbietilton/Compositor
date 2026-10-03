import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// The filters' editor on iPad, and the controls it's made of, as the Mac's filter panel has them.
@MainActor struct PadFilterTests {
    /// The views of `type` in `view`, depth first.
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
    }

    // MARK: Controls

    /// A logarithmic slider gives the small values most of its travel, as the Mac's: halfway along 0.1 to 250 is their
    /// geometric mean, 5, and a value shows where its logarithm falls.
    @Test func aLogarithmicSliderPutsTheGeometricMeanHalfway() throws {
        let row = SliderField(caption: "Radius", sliderRange: 0.1...250, fieldRange: 0.1...250, sensitivity: 0.1, logarithmic: true, decimals: 1)
        var changed: Double?
        row.onChange = { changed = $0 }
        let slider = try #require(views(UISlider.self, in: row).first)
        slider.value = (slider.minimumValue + slider.maximumValue) / 2
        slider.sendActions(for: .valueChanged)
        #expect(changed == 5)
        row.show(1)
        #expect(abs(slider.value - Float(log(1.0))) < 0.0001)
        row.show(250)
        #expect(abs(slider.value - slider.maximumValue) < 0.0001)
    }

    /// The field shows a value with as many decimals as it needs, up to the row's, as the Mac's fields do; the slider
    /// sets values to the row's decimals.
    @Test func theFieldShowsUpToItsDecimals() throws {
        let one = SliderField(caption: "Radius", sliderRange: 0.1...250, fieldRange: 0.1...250, sensitivity: 0.1, logarithmic: true, decimals: 1)
        let field = try #require(views(UITextField.self, in: one).first)
        one.show(1)
        #expect(field.text == "1")
        one.show(1.5)
        #expect(field.text == "1.5")
        let four = SliderField(caption: "Offset", sliderRange: -0.5...0.5, fieldRange: -0.5...0.5, sensitivity: 0.0001, decimals: 4)
        let offset = try #require(views(UITextField.self, in: four).first)
        four.show(0.0125)
        #expect(offset.text == "0.0125")
        four.show(0)
        #expect(offset.text == "0")
        var changed: Double?
        four.onChange = { changed = $0 }
        let slider = try #require(views(UISlider.self, in: four).first)
        slider.value = 0.123456
        slider.sendActions(for: .valueChanged)
        #expect(changed == 0.1235)
    }

    /// Dragging along a caption moves the value evenly, a point of drag to the row's sensitivity, though its slider is
    /// logarithmic, as on the Mac.
    @Test func scrubbingIsEvenOnALogarithmicRow() {
        let row = SliderField(caption: "Radius", sliderRange: 0.1...250, fieldRange: 0.1...250, sensitivity: 0.1, logarithmic: true, decimals: 1)
        #expect(abs(row.scrubbed(from: 3, by: 10) - 4) < 0.0001)
        #expect(abs(row.scrubbed(from: 3, by: -100) - 0.1) < 0.0001)
    }

    /// A group's captions take the widest one's width, so every slider starts and ends in the same place, as the Mac's
    /// filter panel lines them up.
    @Test func captionsLineUp() throws {
        // Sliders that take the room there is, as the filter panel's do.
        let rows = [SliderField(caption: "Amount", sliderRange: 0...100, fieldRange: 0...100, sensitivity: 1, sliderWidth: nil),
                    SliderField(caption: "Highlights", sliderRange: 0...100, fieldRange: 0...100, sensitivity: 1, sliderWidth: nil)]
        SliderField.alignCaptions(rows)
        let column = UIStackView(arrangedSubviews: rows)
        column.axis = .vertical
        column.frame = CGRect(x: 0, y: 0, width: 400, height: 100)
        column.layoutIfNeeded()
        let sliders = rows.compactMap { views(UISlider.self, in: $0).first }
        try #require(sliders.count == 2)
        #expect(sliders[0].frame.minX == sliders[1].frame.minX)
        #expect(sliders[0].frame.width == sliders[1].frame.width)
    }
}
