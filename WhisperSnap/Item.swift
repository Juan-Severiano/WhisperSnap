//
//  Item.swift
//  WhisperSnap
//
//  Created by Francisco Juan on 08/05/26.
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
