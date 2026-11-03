//
//  MapScreen.swift
//  where-are-you
//

import MapKit
import SwiftUI

/// The main screen: a full-screen map of friends, with the People list in a bottom sheet
/// (iPhone) or a side panel (iPad).
struct MapScreen: View {
    @Environment(LocationService.self) private var locationService
    @Environment(FriendsStore.self) private var friendsStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedFriendID: Friend.ID?
    @State private var sheetDetent: PresentationDetent = .peek
    @AppStorage("mapStyle") private var mapStyle: MapStyleChoice = .standard

    private var usesSheet: Bool {
        horizontalSizeClass != .regular
    }

    var body: some View {
        Group {
            if usesSheet {
                mapLayer
            } else {
                HStack(spacing: 0) {
                    PeopleView(selection: $selectedFriendID)
                        .frame(width: 360)
                    Divider()
                        .ignoresSafeArea()
                    mapLayer
                }
            }
        }
        .sheet(isPresented: .constant(usesSheet)) {
            PeopleView(selection: $selectedFriendID)
                .presentationDetents([.peek, .medium, .large], selection: $sheetDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .task(id: friendsStore.reloadToken) {
            await friendsStore.observe()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: locationService.start()
            case .background: locationService.stop()
            default: break
            }
        }
        .onChange(of: selectedFriendID) { _, id in
            focus(on: id)
        }
    }

    private var mapLayer: some View {
        TimelineView(.everyMinute) { context in
            map(now: context.date)
        }
        .overlay(alignment: .topLeading) {
            mapButtons
                .padding(.leading, 8)
                .padding(.top, 8)
        }
        .safeAreaInset(edge: .top) {
            LocationStatusBanner(
                status: locationService.status,
                isAccuracyReduced: locationService.isAccuracyReduced,
                requestPermission: locationService.requestPermission
            )
        }
    }

    private func map(now: Date) -> some View {
        Map(position: $position, selection: $selectedFriendID) {
            UserAnnotation()
            ForEach(friendsStore.friends) { friend in
                if let location = friend.location {
                    if location.isApproximate {
                        MapCircle(center: location.coordinate, radius: location.horizontalAccuracy)
                            .foregroundStyle(friend.avatar.color.color.opacity(0.15))
                            .stroke(friend.avatar.color.color.opacity(0.6), lineWidth: 1)
                    }
                    Annotation(friend.displayName, coordinate: location.coordinate) {
                        FriendPin(friend: friend, location: location, isSelected: selectedFriendID == friend.id, now: now)
                    }
                    .tag(friend.id)
                }
            }
        }
        .mapStyle(mapStyle.mapStyle)
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapPitchToggle()
            MapScaleView()
        }
    }

    private var mapButtons: some View {
        VStack(spacing: 0) {
            Menu {
                Picker("Map Style", selection: $mapStyle) {
                    ForEach(MapStyleChoice.allCases) { choice in
                        Label(choice.title, systemImage: choice.systemImage)
                            .tag(choice)
                    }
                }
            } label: {
                Image(systemName: "map")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Map Style")

            Divider()
                .frame(width: 44)

            Button(action: showEveryone) {
                Image(systemName: "person.2")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Show Everyone")
            .disabled(everyoneCoordinates.isEmpty)
        }
        .font(.system(size: 17, weight: .medium))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
    }

    private var everyoneCoordinates: [CLLocationCoordinate2D] {
        var coordinates = friendsStore.friends.compactMap { $0.location?.coordinate }
        if let user = locationService.userLocation {
            coordinates.append(user.coordinate)
        }
        return coordinates
    }

    private func showEveryone() {
        guard let rect = MapGeometry.rect(enclosing: everyoneCoordinates) else { return }
        selectedFriendID = nil
        sheetDetent = .peek
        withAnimation {
            position = .rect(rect)
        }
    }

    private func focus(on id: Friend.ID?) {
        guard let id else { return }
        // Expand even without a location, so the details explaining why are visible.
        if usesSheet {
            sheetDetent = .medium
        }
        guard let location = friendsStore.friend(id: id)?.location else { return }
        withAnimation {
            position = .region(MapGeometry.region(focusing: location.coordinate, coveredFraction: usesSheet ? 0.5 : 0))
        }
    }
}

extension PresentationDetent {
    /// Just the sheet's title bar and first row, so most of the map stays visible.
    static var peek: PresentationDetent { .height(160) }
}

#if DEBUG
#Preview {
    let dependencies = AppDependencies.preview
    MapScreen()
        .dependencies(dependencies)
        .previewFriends()
        .task { await dependencies.session?.run() }
}
#endif
