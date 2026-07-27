class AppleTools < Formula
  desc "CLIs for local Apple app data: Notes, Mail, Reminders, Calendar, Contacts"
  homepage "https://github.com/danielhopkins/apple-tools"
  url "https://github.com/danielhopkins/apple-tools/releases/download/v26.727.0/apple-tools-26.727.0.tar.gz"
  version "26.727.0"
  sha256 "9bacd45bf6fe8d19d7574581e70ebcf37fe4c329152ac2b40c5bfef75a2c7bd9"
  license "MIT"

  depends_on :macos

  def install
    # apple-notes imports notestore.py as a sibling module, so the two must stay
    # in the same directory. bin/apple-notes is a symlink and the script
    # realpath()s itself, so the import still resolves.
    libexec.install "apple-notes", "notestore.py", "notestore.proto"
    bin.install_symlink libexec/"apple-notes"

    bin.install "apple", "apple-contacts", "apple-mail", "apple-calendar", "reminders"

    doc.install "README.md", "CLAUDE.md", "docs"
  end

  def caveats
    <<~EOS
      Each tool needs a one-time macOS permission grant, prompted on first run
      from a terminal. Run these once and approve each dialog:

        reminders show-lists       # Reminders access
        apple-calendar calendars   # Calendar access
        apple-mail accounts        # Automation access for Mail

      apple-notes and apple-contacts read Apple's SQLite stores directly, which
      requires Full Disk Access for your terminal app:
      System Settings -> Privacy & Security -> Full Disk Access
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/apple --version")
    assert_match version.to_s, shell_output("#{bin}/apple-notes --version")
    assert_match version.to_s, shell_output("#{bin}/apple-contacts --version")
    assert_match version.to_s, shell_output("#{bin}/reminders --version")
    assert_match version.to_s, shell_output("#{bin}/apple-mail --version")
    assert_match version.to_s, shell_output("#{bin}/apple-calendar --version")

    # The dispatcher must find each tool as a sibling in bin.
    assert_match "apple-notes", shell_output("#{bin}/apple --which")

    # --help must work without any TCC grant, so it is safe in a sandbox.
    assert_match "events", shell_output("#{bin}/apple-calendar --help")
  end
end
