import EventKit

extension EKReminder: @retroactive Encodable {
    private enum EncodingKeys: String, CodingKey {
        case externalId
        case lastModified
        case creationDate
        case title
        case notes
        case url
        case location
        case locationTitle
        case completionDate
        case isCompleted
        case priority
        case startDate
        case dueDate
        case list
        case recurrence
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: EncodingKeys.self)
        try container.encode(self.calendarItemExternalIdentifier, forKey: .externalId)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.isCompleted, forKey: .isCompleted)
        try container.encode(self.priority, forKey: .priority)
        try container.encode(self.calendar.title, forKey: .list)
        try container.encodeIfPresent(self.notes, forKey: .notes)

        // url field is nil
        // https://developer.apple.com/forums/thread/128140
        try container.encodeIfPresent(self.url, forKey: .url)
        try container.encodeIfPresent(format(self.completionDate), forKey: .completionDate)

        for alarm in self.alarms ?? [] {
            if let location = alarm.structuredLocation {
                try container.encodeIfPresent(location.title, forKey: .locationTitle)
                if let geoLocation = location.geoLocation {
                    let geo = "\(geoLocation.coordinate.latitude), \(geoLocation.coordinate.longitude)"
                    try container.encode(geo, forKey: .location)
                }
                break
            }
        }

        if let startDateComponents = self.startDateComponents {
            try container.encodeIfPresent(format(startDateComponents.date), forKey: .startDate)
        }

        if let dueDateComponents = self.dueDateComponents {
            try container.encodeIfPresent(format(dueDateComponents.date), forKey: .dueDate)
        }

        if let lastModifiedDate = self.lastModifiedDate {
            try container.encode(format(lastModifiedDate), forKey: .lastModified)
        }

        if let creationDate = self.creationDate {
            try container.encode(format(creationDate), forKey: .creationDate)
        }

        // EventKit allows multiple recurrence rules; the CLI only writes one, so we surface the first.
        if let rule = self.recurrenceRules?.first {
            try container.encode(EncodedRecurrence(rule: rule), forKey: .recurrence)
        }
    }

    private func format(_ date: Date?) -> String? {
        if #available(macOS 12.0, *) {
            return date?.ISO8601Format()
        } else {
            return date?.description(with: .current)
        }
    }
}

private struct EncodedRecurrence: Encodable {
    let frequency: String
    let interval: Int
    let endDate: String?
    let occurrences: Int?

    init(rule: EKRecurrenceRule) {
        switch rule.frequency {
        case .daily:   self.frequency = "daily"
        case .weekly:  self.frequency = "weekly"
        case .monthly: self.frequency = "monthly"
        case .yearly:  self.frequency = "yearly"
        @unknown default: self.frequency = "unknown"
        }
        self.interval = rule.interval
        if let endDate = rule.recurrenceEnd?.endDate {
            if #available(macOS 12.0, *) {
                self.endDate = endDate.ISO8601Format()
            } else {
                self.endDate = endDate.description(with: .current)
            }
        } else {
            self.endDate = nil
        }
        if let end = rule.recurrenceEnd, end.endDate == nil {
            self.occurrences = end.occurrenceCount
        } else {
            self.occurrences = nil
        }
    }
}
