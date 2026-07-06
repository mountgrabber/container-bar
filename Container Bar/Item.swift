//
//  Item.swift
//  Container Manager
//
//  Created by Илья on 06.07.2026.
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
