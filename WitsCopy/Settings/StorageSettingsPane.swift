import SwiftUI
import Defaults

struct StorageSettingsPane: View {
  @Observable
  class ViewModel {
    var saveFiles = false {
      didSet {
        Defaults.withoutPropagation {
          if saveFiles {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.files.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.files.types)
          }
        }
      }
    }

    var saveImages = false {
      didSet {
        Defaults.withoutPropagation {
          if saveImages {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.images.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.images.types)
          }
        }
      }
    }

    var saveText = false {
      didSet {
        Defaults.withoutPropagation {
          if saveText {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.text.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.text.types)
          }
        }
      }
    }

    private var observer: Defaults.Observation?

    init() {
      observer = Defaults.observe(.enabledPasteboardTypes) { change in
        self.saveFiles = change.newValue.isSuperset(of: StorageType.files.types)
        self.saveImages = change.newValue.isSuperset(of: StorageType.images.types)
        self.saveText = change.newValue.isSuperset(of: StorageType.text.types)
      }
    }

    deinit {
      observer?.invalidate()
    }
  }

  @Default(.size) private var size
  @Default(.sortBy) private var sortBy
  @Default(.saveVideos) private var saveVideos
  @Default(.saveAudio) private var saveAudio

  @State private var viewModel = ViewModel()
  @State private var storageSize = Storage.shared.size

  private let sizeFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 999
    return formatter
  }()

  var body: some View {
    SettingsLayout.form {
      SettingsLayout.row("Save", table: "StorageSettings") {
        // Same order as the panel's type filter: text, image, video, audio, file.
        Toggle(
          isOn: $viewModel.saveText,
          label: { Text("Text", tableName: "StorageSettings") }
        )
        .iconHelp(NSLocalizedString("SaveTextHelp", tableName: "StorageSettings", comment: ""))
        Toggle(
          isOn: $viewModel.saveImages,
          label: { Text("Images", tableName: "StorageSettings") }
        )
        .iconHelp(NSLocalizedString("SaveImagesHelp", tableName: "StorageSettings", comment: ""))
        Toggle(
          isOn: $saveVideos,
          label: { Text("Videos", tableName: "StorageSettings") }
        )
        .iconHelp(NSLocalizedString("SaveVideosHelp", tableName: "StorageSettings", comment: ""))
        Toggle(
          isOn: $saveAudio,
          label: { Text("Audio", tableName: "StorageSettings") }
        )
        .iconHelp(NSLocalizedString("SaveAudioHelp", tableName: "StorageSettings", comment: ""))
        Toggle(
          isOn: $viewModel.saveFiles,
          label: { Text("Files", tableName: "StorageSettings") }
        )
        .iconHelp(NSLocalizedString("SaveFilesHelp", tableName: "StorageSettings", comment: ""))
        SettingsLayout.description("SaveDescription", table: "StorageSettings")
      }

      SettingsLayout.sectionBreak()

      SettingsLayout.row("Size", table: "StorageSettings") {
        HStack(spacing: SettingsLayout.stepperSpacing) {
          SettingsNumberField(value: $size, formatter: sizeFormatter)
            .help(Text("SizeTooltip", tableName: "StorageSettings"))
          HelpedStepper(
            value: $size,
            range: 1...999,
            help: NSLocalizedString("SizeStepperHelp", tableName: "StorageSettings", comment: ""),
            identifier: "lab-size-stepper"
          )
          .fixedSize()
        }
      }

      SettingsLayout.row("SortBy", table: "StorageSettings") {
        Picker("", selection: $sortBy) {
          ForEach(Sorter.By.allCases) { mode in
            Text(mode.description)
          }
        }
        .settingsPickerWidth()
        .iconHelp(NSLocalizedString("SortByTooltip", tableName: "StorageSettings", comment: ""))
      }

      SettingsLayout.sectionBreak()

      SettingsLayout.row("HistoryUsage", table: "StorageSettings") {
        VStack(alignment: .leading, spacing: 4) {
          Text(storageSize)
            .onAppear { storageSize = Storage.shared.size }
          SettingsLayout.description("HistoryUsageDescription", table: "StorageSettings")
        }
      }
    }
  }
}

struct HelpedStepper: NSViewRepresentable {
  @Binding var value: Int
  var range: ClosedRange<Int>
  var help: String
  var identifier: String

  func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

  final class Coordinator: NSObject {
    var value: Binding<Int>
    init(value: Binding<Int>) { self.value = value }
    @objc func changed(_ sender: NSStepper) {
      value.wrappedValue = sender.integerValue
    }
  }

  func makeNSView(context: Context) -> NSStepper {
    let stepper = NSStepper()
    configure(stepper, context: context)
    return stepper
  }

  func updateNSView(_ stepper: NSStepper, context: Context) {
    context.coordinator.value = $value
    configure(stepper, context: context)
  }

  private func configure(_ stepper: NSStepper, context: Context) {
    stepper.minValue = Double(range.lowerBound)
    stepper.maxValue = Double(range.upperBound)
    stepper.increment = 1
    stepper.valueWraps = false
    stepper.autorepeat = true
    if stepper.integerValue != value {
      stepper.integerValue = value
    }
    stepper.toolTip = help
    stepper.setAccessibilityElement(true)
    stepper.setAccessibilityHelp(help)
    stepper.setAccessibilityIdentifier(identifier)
    stepper.target = context.coordinator
    stepper.action = #selector(Coordinator.changed(_:))
  }
}

#Preview {
  StorageSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
