//
//  Item.swift
//  DuplicityManager
//
//  Created by Enrico Lévesque on 2026-06-29.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
