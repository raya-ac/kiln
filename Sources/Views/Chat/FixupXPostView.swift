import SwiftUI

struct FixupXPostView: View {
    let post: FixupXPost

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(post.author).font(.system(size: 14, weight: .semibold))
                Text("@" + post.handle).font(.system(size: 12)).foregroundStyle(Color.kilnTextSecondary)
            }
            Text(post.text).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            ForEach(post.media) { item in InlineMediaView(media: item.reference, workDir: "") }
            if let quote = post.quote {
                VStack(alignment: .leading, spacing: 8) {
                    Text(quote.author + " @" + quote.handle).font(.system(size: 12, weight: .medium))
                    Text(quote.text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    ForEach(quote.media) { item in InlineMediaView(media: item.reference, workDir: "") }
                }.padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(Color.kilnBorder).frame(width: 2) }
            }
            if let timestamp = post.timestamp {
                Text(Date(timeIntervalSince1970: timestamp), format: .dateTime.day().month().year().hour().minute())
                    .font(.system(size: 11)).foregroundStyle(Color.kilnTextSecondary)
            }
        }
    }
}
