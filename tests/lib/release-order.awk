/git tag|git push origin "\$VERSION"|uses: softprops\/action-gh-release/ { exit 1 }
/bash scripts\/build-tarball.sh/ { if (notes || publish) exit 1; build++ }
/scripts\/lib\/release_notes.py render --verified/ { if (build != 1 || publish) exit 1; notes++ }
/scripts\/lib\/publish_release.py/ { if (notes != 1) exit 1; publish++ }
END { if (build != 1 || notes != 1 || publish != 1) exit 1 }
