//
//  TunnelConstants.swift
//  AirCard-iOS
//
//  Shared between the app and the embedded packet-tunnel extension.
//  Ported from LocalDevVPN (https://github.com/...), MIT licensed.
//

import Foundation

struct TunnelConstants {
    static let ifaceIPConfigurationKey = "TunnelIfaceIP"
    static let peerIPConfigurationKey = "TunnelPeerIP"

    static let defaultIfaceIP = "10.7.1.1/32"
    static let defaultPeerIP = "10.7.0.1/32"
    static let defaultAllowIntermediateAddresses = true
}
