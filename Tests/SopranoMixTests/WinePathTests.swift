import AppKit
import Testing
@testable import SopranoMixCore

struct WinePathTests {
    private let tekken = #"C:\Program Files (x86)\Steam\steamapps\common\TEKKEN 8\Polaris\Binaries\Win64\Polaris-Win64-Shipping.exe"#

    @Test("only drive-letter backslash paths are Windows paths")
    func windowsPathDetection() {
        #expect(WinePath.isWindowsPath(tekken))
        #expect(WinePath.isWindowsPath(#"z:\Users\furkan\game.exe"#))
        #expect(!WinePath.isWindowsPath("/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64-preloader"))
        #expect(!WinePath.isWindowsPath("C:/forward/slashes.exe"))
        #expect(!WinePath.isWindowsPath("C:"))
        #expect(!WinePath.isWindowsPath(#"1:\x"#))
        #expect(!WinePath.isWindowsPath(""))
    }

    @Test("Steam games are named after their steamapps common folder")
    func steamGames() {
        #expect(WinePath.appName(forWindowsPath: tekken) == "TEKKEN 8")
        #expect(WinePath.appName(forWindowsPath: #"D:\SteamLibrary\SteamApps\Common\Elden Ring\Game\eldenring.exe"#) == "Elden Ring")
    }

    @Test("Steam itself and its web helper are Steam")
    func steamClient() {
        #expect(WinePath.appName(forWindowsPath: #"C:\Program Files (x86)\Steam\bin\cef\cef.win7x64\steamwebhelper.exe"#) == "Steam")
        #expect(WinePath.appName(forWindowsPath: #"C:\Program Files (x86)\Steam\steam.exe"#) == "Steam")
        #expect(WinePath.appName(forWindowsPath: #"C:\Program Files\STEAM\Steam.exe"#) == "Steam")
    }

    @Test("Program Files folders, GOG and Epic games name the app, Common Files does not")
    func installFolders() {
        #expect(WinePath.appName(forWindowsPath: #"C:\Program Files\Battle.net\Battle.net.exe"#) == "Battle.net")
        #expect(WinePath.appName(forWindowsPath: #"C:\GOG Games\Cyberpunk 2077\bin\x64\Cyberpunk2077.exe"#) == "Cyberpunk 2077")
        #expect(WinePath.appName(forWindowsPath: #"C:\Program Files\Epic Games\Fortnite\FortniteClient.exe"#) == "Fortnite")
        #expect(WinePath.appName(forWindowsPath: #"C:\Program Files\Common Files\Vendor\helper.EXE"#) == "helper")
    }

    @Test("other paths give the file name without .exe")
    func fileNameFallback() {
        #expect(WinePath.appName(forWindowsPath: #"C:\windows\system32\winedevice.exe"#) == "winedevice")
        #expect(WinePath.appName(forWindowsPath: #"C:\Games\Doom.Exe"#) == "Doom")
        #expect(WinePath.appName(forWindowsPath: #"C:\Program Files\tool.exe"#) == "tool")
        #expect(WinePath.appName(forWindowsPath: #"C:\run.bat"#) == "run.bat")
    }

    @Test("Windows paths map into the Wine prefix by drive")
    func macPaths() {
        let prefix = "/Users/f/Library/Application Support/CrossOver/Bottles/Steam/"
        #expect(WinePath.macPath(forWindowsPath: #"C:\a\b.exe"#, prefix: prefix)
            == "/Users/f/Library/Application Support/CrossOver/Bottles/Steam/drive_c/a/b.exe")
        #expect(WinePath.macPath(forWindowsPath: #"Z:\Users\x"#, prefix: prefix) == "/Users/x")
        #expect(WinePath.macPath(forWindowsPath: #"D:\Games\g.exe"#, prefix: "/p")
            == "/p/dosdevices/d:/Games/g.exe")
        #expect(WinePath.macPath(forWindowsPath: "/usr/bin/afplay", prefix: "/p") == nil)
    }
}
