import SwiftUI

/// A fixed catalogue of names, never a scan or an image cache. Symbol images
/// are requested by the lazy grid only while its small popover is visible.
enum NidusSymbolCatalog {
    struct Choice: Identifiable, Sendable {
        let symbol: String
        let name: String
        let group: String
        var id: String { symbol }
    }
    static let groups = ["Work", "Study", "Creative", "Health", "Social", "Media", "Shopping", "Travel"]
    static let choices: [Choice] = [
        .init(symbol: "brain", name: "Focus", group: "Work"),
        .init(symbol: "bolt", name: "Setup", group: "Work"),
        .init(symbol: "folder", name: "Project", group: "Work"),
        .init(symbol: "briefcase", name: "Work", group: "Work"),
        .init(symbol: "desktopcomputer", name: "Desktop", group: "Work"),
        .init(symbol: "laptopcomputer", name: "Laptop", group: "Work"),
        .init(symbol: "keyboard", name: "Keyboard", group: "Work"),
        .init(symbol: "terminal", name: "Terminal", group: "Work"),
        .init(symbol: "chevron.left.forwardslash.chevron.right", name: "Code", group: "Work"),
        .init(symbol: "calendar", name: "Calendar", group: "Work"),
        .init(symbol: "calendar.badge.clock", name: "Schedule", group: "Work"),
        .init(symbol: "list.number", name: "Sequence", group: "Work"),
        .init(symbol: "checklist", name: "Checklist", group: "Work"),
        .init(symbol: "doc.text", name: "Document", group: "Work"),
        .init(symbol: "tray", name: "Inbox", group: "Work"),
        .init(symbol: "book", name: "Book", group: "Study"),
        .init(symbol: "books.vertical", name: "Library", group: "Study"),
        .init(symbol: "graduationcap", name: "Study", group: "Study"),
        .init(symbol: "pencil", name: "Writing", group: "Study"),
        .init(symbol: "pencil.and.outline", name: "Draft", group: "Study"),
        .init(symbol: "note.text", name: "Notes", group: "Study"),
        .init(symbol: "text.book.closed", name: "Textbook", group: "Study"),
        .init(symbol: "bookmark", name: "Bookmark", group: "Study"),
        .init(symbol: "magnifyingglass", name: "Research", group: "Study"),
        .init(symbol: "flask", name: "Experiment", group: "Study"),
        .init(symbol: "testtube.2", name: "Lab", group: "Study"),
        .init(symbol: "atom", name: "Atom", group: "Study"),
        .init(symbol: "function", name: "Math", group: "Study"),
        .init(symbol: "chart.bar", name: "Data", group: "Study"),
        .init(symbol: "lightbulb", name: "Idea", group: "Study"),
        .init(symbol: "paintpalette", name: "Palette", group: "Creative"),
        .init(symbol: "paintbrush", name: "Paint", group: "Creative"),
        .init(symbol: "pencil.tip", name: "Sketch", group: "Creative"),
        .init(symbol: "camera", name: "Camera", group: "Creative"),
        .init(symbol: "photo", name: "Photo", group: "Creative"),
        .init(symbol: "scissors", name: "Cut", group: "Creative"),
        .init(symbol: "ruler", name: "Measure", group: "Creative"),
        .init(symbol: "square.stack", name: "Layers", group: "Creative"),
        .init(symbol: "scribble", name: "Draw", group: "Creative"),
        .init(symbol: "wand.and.stars", name: "Effects", group: "Creative"),
        .init(symbol: "sparkles", name: "Sparkles", group: "Creative"),
        .init(symbol: "cube", name: "Model", group: "Creative"),
        .init(symbol: "hammer", name: "Build", group: "Creative"),
        .init(symbol: "wrench.and.screwdriver", name: "Tools", group: "Creative"),
        .init(symbol: "lightbulb.max", name: "Inspiration", group: "Creative"),
        .init(symbol: "heart", name: "Health", group: "Health"),
        .init(symbol: "leaf", name: "Leaf", group: "Health"),
        .init(symbol: "moon", name: "Rest", group: "Health"),
        .init(symbol: "sun.max", name: "Morning", group: "Health"),
        .init(symbol: "cup.and.saucer", name: "Break", group: "Health"),
        .init(symbol: "figure.walk", name: "Walk", group: "Health"),
        .init(symbol: "figure.run", name: "Run", group: "Health"),
        .init(symbol: "figure.yoga", name: "Yoga", group: "Health"),
        .init(symbol: "bed.double", name: "Sleep", group: "Health"),
        .init(symbol: "cross.case", name: "Medicine", group: "Health"),
        .init(symbol: "pills", name: "Medication", group: "Health"),
        .init(symbol: "stethoscope", name: "Care", group: "Health"),
        .init(symbol: "lungs", name: "Breathe", group: "Health"),
        .init(symbol: "drop", name: "Water", group: "Health"),
        .init(symbol: "flame", name: "Energy", group: "Health"),
        .init(symbol: "person", name: "Person", group: "Social"),
        .init(symbol: "person.2", name: "Social", group: "Social"),
        .init(symbol: "person.3", name: "Group", group: "Social"),
        .init(symbol: "bubble.left.and.bubble.right", name: "Messaging", group: "Social"),
        .init(symbol: "text.bubble", name: "Forum", group: "Social"),
        .init(symbol: "envelope", name: "Mail", group: "Social"),
        .init(symbol: "phone", name: "Call", group: "Social"),
        .init(symbol: "video", name: "Video call", group: "Social"),
        .init(symbol: "hand.wave", name: "Hello", group: "Social"),
        .init(symbol: "hand.thumbsup", name: "Like", group: "Social"),
        .init(symbol: "at", name: "Mention", group: "Social"),
        .init(symbol: "link", name: "Link", group: "Social"),
        .init(symbol: "network", name: "Network", group: "Social"),
        .init(symbol: "person.crop.circle", name: "Profile", group: "Social"),
        .init(symbol: "bell", name: "Notifications", group: "Social"),
        .init(symbol: "play.rectangle", name: "Video", group: "Media"),
        .init(symbol: "play.circle", name: "Play", group: "Media"),
        .init(symbol: "music.note", name: "Music", group: "Media"),
        .init(symbol: "headphones", name: "Audio", group: "Media"),
        .init(symbol: "mic", name: "Microphone", group: "Media"),
        .init(symbol: "waveform", name: "Sound", group: "Media"),
        .init(symbol: "film", name: "Film", group: "Media"),
        .init(symbol: "tv", name: "Television", group: "Media"),
        .init(symbol: "newspaper", name: "News", group: "Media"),
        .init(symbol: "radio", name: "Radio", group: "Media"),
        .init(symbol: "gamecontroller", name: "Games", group: "Media"),
        .init(symbol: "sportscourt", name: "Sports", group: "Media"),
        .init(symbol: "headphones.circle", name: "Listen", group: "Media"),
        .init(symbol: "record.circle", name: "Record", group: "Media"),
        .init(symbol: "theatermasks", name: "Theatre", group: "Media"),
        .init(symbol: "cart", name: "Shopping", group: "Shopping"),
        .init(symbol: "bag", name: "Bag", group: "Shopping"),
        .init(symbol: "basket", name: "Basket", group: "Shopping"),
        .init(symbol: "tag", name: "Tag", group: "Shopping"),
        .init(symbol: "gift", name: "Gift", group: "Shopping"),
        .init(symbol: "creditcard", name: "Card", group: "Shopping"),
        .init(symbol: "banknote", name: "Money", group: "Shopping"),
        .init(symbol: "dollarsign.circle", name: "Budget", group: "Shopping"),
        .init(symbol: "chart.line.uptrend.xyaxis", name: "Finance", group: "Shopping"),
        .init(symbol: "building.columns", name: "Bank", group: "Shopping"),
        .init(symbol: "shippingbox", name: "Delivery", group: "Shopping"),
        .init(symbol: "storefront", name: "Store", group: "Shopping"),
        .init(symbol: "receipt", name: "Receipt", group: "Shopping"),
        .init(symbol: "tshirt", name: "Clothes", group: "Shopping"),
        .init(symbol: "fork.knife", name: "Food", group: "Shopping"),
        .init(symbol: "airplane", name: "Flight", group: "Travel"),
        .init(symbol: "tram", name: "Transit", group: "Travel"),
        .init(symbol: "bus", name: "Bus", group: "Travel"),
        .init(symbol: "car", name: "Car", group: "Travel"),
        .init(symbol: "bicycle", name: "Bicycle", group: "Travel"),
        .init(symbol: "map", name: "Map", group: "Travel"),
        .init(symbol: "location", name: "Location", group: "Travel"),
        .init(symbol: "globe", name: "World", group: "Travel"),
        .init(symbol: "mountain.2", name: "Mountains", group: "Travel"),
        .init(symbol: "tent", name: "Camping", group: "Travel"),
        .init(symbol: "tree", name: "Nature", group: "Travel"),
        .init(symbol: "house", name: "Home", group: "Travel"),
        .init(symbol: "building.2", name: "City", group: "Travel"),
        .init(symbol: "suitcase", name: "Travel", group: "Travel"),
        .init(symbol: "sun.haze", name: "Outside", group: "Travel"),
    ]

    static func results(query: String, group: String? = nil) -> [Choice] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return choices.filter { choice in
            (group == nil || choice.group == group) && terms.allSatisfy {
                (choice.name + " " + choice.group + " " + choice.symbol).localizedStandardContains($0)
            }
        }
    }

    static func name(for symbol: String) -> String {
        choices.first { $0.symbol == symbol }?.name ?? symbol
    }
}

/// A compact preview rather than an always-mounted grid on every form.
struct NidusSymbolPicker: View {
    @Binding var selection: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 8) {
                Image(systemName: selection)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Solanum.clayText)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text("Choose symbol…")
            }
        }
        .buttonStyle(.bordered)
        .help("Choose a symbol for this category or setup")
        .accessibilityLabel("Choose symbol")
        .accessibilityValue(NidusSymbolCatalog.name(for: selection))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            NidusSymbolBrowser(selection: $selection) { isPresented = false }
        }
    }
}

struct NidusSymbolBrowser: View {
    @Binding var selection: String
    var close: () -> Void = {}
    @State private var query = ""
    @State private var group = "All"
    @FocusState private var searchFocused: Bool
    private static let columns = Array(repeating: GridItem(.fixed(40), spacing: 6), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Choose a symbol")
                    .font(Solanum.serif(20))
                    .foregroundStyle(Solanum.ink)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 22, height: 22) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Solanum.inkMuted)
                    .help("Close symbol picker")
                    .accessibilityLabel("Close symbol picker")
            }
            TextField("Search symbols", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityLabel("Search symbols")
            HStack {
                Picker("Group", selection: $group) {
                    Text("All groups").tag("All")
                    ForEach(NidusSymbolCatalog.groups, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 165)
                Spacer()
                Text("\(found.count) symbols")
                    .font(.caption)
                    .foregroundStyle(Solanum.inkMuted)
            }
            ScrollView {
                if found.isEmpty {
                    Text("No symbols found. Try another word or group.")
                        .foregroundStyle(Solanum.inkMuted)
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    LazyVGrid(columns: Self.columns, spacing: 6) {
                        ForEach(found) { choice in
                            let selected = selection == choice.symbol
                            Button {
                                selection = choice.symbol
                                close()
                            } label: {
                                Image(systemName: choice.symbol)
                                    .font(.system(size: 18))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(selected ? Solanum.onClay : Solanum.clayText)
                                    .frame(width: 40, height: 36)
                                    .background(selected ? Solanum.clay : Solanum.raised,
                                                in: .rect(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(selected ? Solanum.clayText : Solanum.hairline))
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help(choice.name + " · " + choice.group)
                            .accessibilityLabel(choice.name)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(height: 226)
            .id(group + query)
        }
        .padding(16)
        .frame(width: 350)
        .background(Solanum.page)
        .onAppear { searchFocused = true }
        .onExitCommand(perform: close)
    }

    private var found: [NidusSymbolCatalog.Choice] {
        NidusSymbolCatalog.results(query: query, group: group == "All" ? nil : group)
    }
}
