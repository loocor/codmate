import Foundation

struct GeminiUsageStatus: Equatable {
  struct Bucket: Equatable {
    let modelId: String?
    let tokenType: String?
    let remainingFraction: Double?
    let remainingAmount: String?
    let resetTime: Date?
  }

  let updatedAt: Date
  let projectId: String?
  let buckets: [Bucket]
  let planType: String?  // Subscription type (AI Pro, AI Ultra, etc.)

  func asProviderSnapshot(titleBadge: String? = nil) -> UsageProviderSnapshot {
    // Group buckets by model ID to find the lowest quota per model
    // (input/output tokens might have different quotas; show the more limiting one)
    var modelQuotaMap: [String: Bucket] = [:]
    for bucket in buckets {
      guard let modelId = bucket.modelId, !modelId.isEmpty else { continue }
      if let existing = modelQuotaMap[modelId] {
        // Keep the bucket with lower remaining fraction (more constrained)
        if let newFraction = bucket.remainingFraction,
           let existingFraction = existing.remainingFraction,
           newFraction < existingFraction
        {
          modelQuotaMap[modelId] = bucket
        }
      } else {
        modelQuotaMap[modelId] = bucket
      }
    }

    // Sort models by name, showing used models first (lower remaining fraction)
    let sortedModels = modelQuotaMap.sorted { a, b in
      let aUsed = (a.value.remainingFraction ?? 1.0) < 1.0
      let bUsed = (b.value.remainingFraction ?? 1.0) < 1.0
      if aUsed != bUsed { return aUsed }
      return a.key.localizedStandardCompare(b.key) == .orderedAscending
    }

    // Create metrics for models - show ALL models with quotas
    // Models with usage (remainingFraction < 1.0) show full details
    // Models without usage show a simplified "available" state
    let metrics: [UsageMetricSnapshot] = sortedModels.compactMap { modelId, bucket in
      let remaining = bucket.remainingFraction?.clamped01()
      let hasBeenUsed = (remaining ?? 1.0) < 1.0

      // For unused models, show a simplified display
      let percentText: String? = {
        guard let remaining else { return nil }
        if hasBeenUsed {
          return NumberFormatter.compactPercentFormatter.string(from: NSNumber(value: remaining))
            ?? String(format: "%.0f%%", remaining * 100)
        }
        return "100%"
      }()

      let label = modelId

      let usageText: String? = {
        if hasBeenUsed {
          if let amount = bucket.remainingAmount, !amount.isEmpty {
            return "Remaining \(amount)"
          }
        }
        return nil
      }()

      return UsageMetricSnapshot(
        kind: .quota,
        label: label,
        usageText: usageText,
        percentText: percentText,
        progress: remaining ?? 1.0,
        resetDate: bucket.resetTime,
        fallbackWindowMinutes: 1440  // 24h default for Gemini quotas
      )
    }

    // Availability: ready if we have any buckets, empty only if no data at all
    let availability: UsageProviderSnapshot.Availability = buckets.isEmpty ? .empty : .ready

    // Count used models
    let usedModels = sortedModels.filter { (_, bucket) in
      (bucket.remainingFraction ?? 1.0) < 1.0
    }.count
    let totalModels = sortedModels.count

    let statusMessage: String? = {
      if buckets.isEmpty {
        return "No Gemini usage data."
      }
      if usedModels == 0 && totalModels > 0 {
        return "No models used yet. Quotas available for \(totalModels) models."
      }
      return nil
    }()

    return UsageProviderSnapshot(
      provider: .gemini,
      title: UsageProviderKind.gemini.displayName,
      titleBadge: titleBadge,
      availability: availability,
      metrics: metrics,
      updatedAt: updatedAt,
      statusMessage: statusMessage,
      origin: .builtin
    )
  }
}

private extension Double {
  func clamped01() -> Double { max(0, min(self, 1)) }
}
