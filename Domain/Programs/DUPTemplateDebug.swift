import Foundation

enum DUPTemplateDebug {
    static func printDay(
        weekNumber: Int,
        dayNumber: Int
    ) {
        do {
            let day = try DUPSessionMaterializer.materializeDay(
                template: DUP10WeekTemplate.template,
                weekNumber: weekNumber,
                dayNumber: dayNumber
            )

            print("====================================")
            print("TEMPLATE: \(day.templateId)")
            print("WEEK: \(day.weekNumber)")
            print("WAVE: \(day.wave.displayName)")
            print("DAY: \(day.dayNumber)")
            print("TITLE: \(day.title)")
            print("ROLE: \(day.role)")
            print("------------------------------------")

            for ex in day.exercises {
                print("""
                ORDER: \(ex.order)
                EXERCISE ID: \(ex.exerciseId)
                PRIORITY: \(ex.priority.rawValue)
                SETS: \(ex.setMin)-\(ex.setMax)
                REPS: \(ex.repMin)-\(ex.repMax)
                RIR: \(ex.targetRIRMin)-\(ex.targetRIRMax)
                INTENSIFIER: \(ex.intensifier.rawValue)
                NOTES: \(ex.notes ?? "none")
                INTENSIFIER NOTES: \(ex.intensifierNotes ?? "none")
                DEFAULT SETS: \(ex.defaultSets)
                DEFAULT TARGET REPS: \(ex.defaultTargetReps)
                DEFAULT TARGET RIR: \(ex.defaultTargetRIR)
                ------------------------------------
                """)
            }

        } catch {
            print("DUPTemplateDebug.printDay failed: \(error)")
        }
    }
}

