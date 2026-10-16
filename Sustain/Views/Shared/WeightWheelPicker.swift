import SwiftUI

/// A two-wheel scroll picker (whole number + tenths) for entering a body
/// weight, replacing the numeric-keyboard `TextField` every weight-entry
/// screen used to have — explicit request: "all areas where you type weight
/// should be a scroll wheel instead." Modeled on the same whole+fraction
/// wheel pattern Apple's own Health app uses for weight entry, rather than
/// a single wheel with hundreds of fractional rows (which scrolls far
/// slower to reach a specific value).
///
/// `weight` is in whatever unit `unit` says it's in — same convention every
/// other weight field in this app already follows (the view model/local
/// `@State` holds a plain display-unit `Double`, and callers convert to/from
/// pounds for storage themselves). This view never does unit conversion; it
/// only reads `unit` to pick a sensible whole-number range and abbreviation.
struct WeightWheelPicker: View {
    @Binding var weight: Double
    let unit: WeightUnit

    /// Generous enough to cover real adult body weights in either unit
    /// without the wheel feeling oddly short at either extreme — bariatric
    /// care specifically (this app's actual audience) means the lower bound
    /// especially shouldn't clip anyone close to a real goal weight.
    private var wholeRange: ClosedRange<Int> {
        switch unit {
        case .pounds: return 50...600
        case .kilograms: return 20...270
        }
    }

    private var wholePart: Binding<Int> {
        Binding(
            get: { max(wholeRange.lowerBound, min(wholeRange.upperBound, Int(weight))) },
            set: { newValue in
                let tenths = ((weight - weight.rounded(.towardZero)) * 10).rounded()
                weight = Double(newValue) + tenths / 10
            }
        )
    }

    private var tenthsPart: Binding<Int> {
        Binding(
            get: { Int(((weight - weight.rounded(.towardZero)) * 10).rounded()) },
            set: { newValue in
                weight = Double(Int(weight)) + Double(newValue) / 10
            }
        )
    }

    var body: some View {
        HStack(spacing: 4) {
            Picker("", selection: wholePart) {
                ForEach(wholeRange, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .pickerStyle(.wheel)
            .frame(width: 80)

            Text(".")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("", selection: tenthsPart) {
                ForEach(0..<10) { value in
                    Text("\(value)").tag(value)
                }
            }
            .pickerStyle(.wheel)
            .frame(width: 50)

            Text(unit.abbreviation)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
        .frame(height: 110)
        .clipped()
    }
}

private struct WeightWheelPickerPreview: View {
    @State private var weight: Double = 182.5
    var body: some View {
        WeightWheelPicker(weight: $weight, unit: .pounds)
    }
}

#Preview {
    WeightWheelPickerPreview()
}
