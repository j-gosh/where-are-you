//
//  MapStyleChoice.swift
//  where-are-you
//

import MapKit
import SwiftUI

enum MapStyleChoice: String, CaseIterable, Identifiable {
    case standard
    case hybrid
    case satellite

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .standard: "Standard"
        case .hybrid: "Hybrid"
        case .satellite: "Satellite"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "map"
        case .hybrid: "map.fill"
        case .satellite: "globe.americas.fill"
        }
    }

    var mapStyle: MapStyle {
        switch self {
        case .standard: .standard(elevation: .realistic)
        case .hybrid: .hybrid(elevation: .realistic)
        case .satellite: .imagery(elevation: .realistic)
        }
    }
}
