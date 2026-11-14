import SwiftUI

struct AppImageView: View {
  let appImage: SourceIcon
  let size: CGSize

  var body: some View {
    switch appImage {
    case .application(let image):
      Image(nsImage: image.nsImage)
        .resizable()
        .frame(width: size.width, height: size.height)
    case .systemSymbol(let name):
      Image(systemName: name)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: size.width, height: size.height)
        .symbolRenderingMode(.monochrome)
    }
  }
}
