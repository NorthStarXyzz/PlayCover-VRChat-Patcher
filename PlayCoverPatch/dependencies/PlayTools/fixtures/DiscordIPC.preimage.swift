
        activity.timestamps.start = Date()

        activity.buttons[0].label = "Download PlayCover"
        activity.buttons[0].url = "https://github.com/PlayCover/PlayCover/releases"
        activity.buttons.removeLast()

        return activity
    }
