
        activity.timestamps.start = Date()

        activity.buttons = [
            RichPresence.Button(label: "Download PlayCover",
                                url: "https://github.com/PlayCover/PlayCover/releases")
        ]

        return activity
    }
