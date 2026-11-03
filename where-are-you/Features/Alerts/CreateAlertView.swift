//
//  CreateAlertView.swift
//  where-are-you
//

import MapKit
import SwiftUI
import WAYCore

/// "Notify me when Olivia arrives at/leaves …": pick a place on the map, a radius and a trigger.
struct CreateAlertView: View {
    let friend: Friend

    @Environment(AlertService.self) private var alerts
    @Environment(PushService.self) private var push
    @Environment(LocationService.self) private var locationService
    @Environment(\.dismiss) private var dismiss

    @State private var position: MapCameraPosition
    @State private var center: CLLocationCoordinate2D
    @State private var radius: Double = 200
    @State private var trigger: AlertTrigger = .arrive
    @State private var placeName = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(friend: Friend, start: CLLocationCoordinate2D) {
        self.friend = friend
        _center = State(initialValue: start)
        _position = State(initialValue: .region(MKCoordinateRegion(center: start, latitudinalMeters: 1_500, longitudinalMeters: 1_500)))
    }

    private var request: AlertRequest {
        AlertRequest(id: "draft", placeName: placeName.trimmingCharacters(in: .whitespacesAndNewlines), latitude: center.latitude, longitude: center.longitude, radius: radius, trigger: trigger)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Map(position: $position) {
                        MapCircle(center: center, radius: radius)
                            .foregroundStyle(.tint.opacity(0.2))
                            .stroke(.tint, lineWidth: 2)
                    }
                    .onMapCameraChange(frequency: .continuous) { context in
                        center = context.region.center
                    }
                    .overlay {
                        Image(systemName: "mappin")
                            .font(.title)
                            .foregroundStyle(.tint)
                            .offset(y: -12)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Move the map to put the pin on the place.")
                }

                Section {
                    TextField("Place name, like Home", text: $placeName)
                        .accessibilityIdentifier("alertPlaceName")
                    Picker("Notify Me When \(friend.displayName)", selection: $trigger) {
                        Text("Arrives").tag(AlertTrigger.arrive)
                        Text("Leaves").tag(AlertTrigger.leave)
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading) {
                        Text("Radius: \(Measurement(value: radius, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))")
                        Slider(value: $radius, in: AlertRequest.radiusRange.lowerBound...1_000, step: 50)
                    }
                } footer: {
                    Text("\(friend.displayName) will be told you set this alert and can remove it. Their phone checks the place, so the server never learns where it is.")
                }
            }
            .navigationTitle("Location Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await save() }
                    }
                    .disabled((try? request.validate()) == nil || isSaving)
                }
            }
            .errorAlert($errorMessage)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await alerts.createAlert(on: friend, placeName: placeName, latitude: center.latitude, longitude: center.longitude, radius: radius, trigger: trigger)
            if push.permission == .notDetermined {
                await push.requestPermission()
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
