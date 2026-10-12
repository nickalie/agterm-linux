import Testing
@testable import AgtermLinux

@Suite("GDK kept off GLES for libghostty's desktop GL")
struct LinuxGLEnvironmentTests {
    @Test("GTK 4.16+ disables the GLES API, appending to what the user set")
    func disablesGLES() throws {
        let fresh = try #require(LinuxGLEnvironment.gdkOverride(gtkMinor: 24, environment: [:]))
        #expect(fresh == ("GDK_DISABLE", "gles-api"))
        let appended = try #require(LinuxGLEnvironment.gdkOverride(gtkMinor: 16, environment: ["GDK_DISABLE": "vulkan"]))
        #expect(appended == ("GDK_DISABLE", "vulkan,gles-api"))
        #expect(LinuxGLEnvironment.gdkOverride(gtkMinor: 24, environment: ["GDK_DISABLE": "vulkan,gles-api"]) == nil)
    }

    @Test("GTK 4.14 and 4.15 take the older GDK_DEBUG switch; earlier GTK has none")
    func olderGTK() throws {
        let debug = try #require(LinuxGLEnvironment.gdkOverride(gtkMinor: 14, environment: ["GDK_DEBUG": "misc"]))
        #expect(debug == ("GDK_DEBUG", "misc,gl-disable-gles"))
        #expect(LinuxGLEnvironment.gdkOverride(gtkMinor: 15, environment: ["GDK_DEBUG": "gl-disable-gles"]) == nil)
        #expect(LinuxGLEnvironment.gdkOverride(gtkMinor: 12, environment: [:]) == nil)
    }
}
