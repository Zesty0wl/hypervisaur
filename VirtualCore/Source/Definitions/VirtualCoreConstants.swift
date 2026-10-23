//
//  VirtualCoreConstants.swift
//  VirtualCore
//
//  Created by Guilherme Rambo on 02/06/22.
//

import Foundation
import OSLog
@_exported import BuddyFoundation

struct VirtualCoreConstants {
    static let subsystemName = "com.neiljohn.hypervisaur.VirtualCore"
}

private final class _VirtualCoreStub { }

public extension Bundle {
    static let virtualCore = Bundle(for: _VirtualCoreStub.self)
}
