//! Extension points for optional add-ons (ADR-0009).
//!
//! The free core is complete without any extension. An add-on, such as a future paid feature
//! in a separate private repository, implements [`Extension`] and is handed to a [`Registry`]
//! by the shell that ships it. The free build registers nothing.
//!
//! Rules (ADR-0008, ADR-0009):
//! - One-way dependency: add-ons depend on this crate; no core crate depends on an add-on.
//! - Observe only: hooks see finished results but cannot change the text, block insertion or
//!   slow the dictation path. A missing or failing add-on never degrades the free app.
//! - No network, accounts or licence checks live here.

use std::fmt;

/// A dictation the core has finished and delivered (or tried to deliver).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FinishedDictation<'a> {
    /// The cleaned text the core produced.
    pub text: &'a str,
    /// Detected or chosen language, when known (for example "en").
    pub language: Option<&'a str>,
    /// Whether the text reached the target app.
    pub inserted: bool,
}

/// An optional add-on. Every hook has a no-op default, so an extension implements only what
/// it needs and new hooks can be added without breaking existing add-ons.
pub trait Extension: Send {
    /// Stable, unique identifier, for example "dev.dclabs.sync".
    fn id(&self) -> &'static str;

    /// Called after a dictation finishes. Observe only: the text has already been delivered.
    fn on_dictation_finished(&mut self, _dictation: &FinishedDictation<'_>) {}
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegistryError {
    /// Two extensions claimed the same id.
    DuplicateId(&'static str),
}

impl fmt::Display for RegistryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RegistryError::DuplicateId(id) => {
                write!(f, "extension id {id:?} is already registered")
            }
        }
    }
}

impl std::error::Error for RegistryError {}

/// The extensions a build ships with. [`Registry::default`] is empty, which is the free build.
#[derive(Default)]
pub struct Registry {
    extensions: Vec<Box<dyn Extension>>,
}

impl Registry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, extension: Box<dyn Extension>) -> Result<(), RegistryError> {
        let id = extension.id();
        if self.extensions.iter().any(|e| e.id() == id) {
            return Err(RegistryError::DuplicateId(id));
        }
        self.extensions.push(extension);
        Ok(())
    }

    pub fn len(&self) -> usize {
        self.extensions.len()
    }

    pub fn is_empty(&self) -> bool {
        self.extensions.is_empty()
    }

    pub fn ids(&self) -> Vec<&'static str> {
        self.extensions.iter().map(|e| e.id()).collect()
    }

    /// Tell every extension, in registration order, that a dictation finished.
    pub fn dictation_finished(&mut self, dictation: &FinishedDictation<'_>) {
        for extension in &mut self.extensions {
            extension.on_dictation_finished(dictation);
        }
    }
}

impl fmt::Debug for Registry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Registry")
            .field("extensions", &self.ids())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    struct Recorder {
        id: &'static str,
        seen: Arc<Mutex<Vec<String>>>,
    }

    impl Extension for Recorder {
        fn id(&self) -> &'static str {
            self.id
        }
        fn on_dictation_finished(&mut self, d: &FinishedDictation<'_>) {
            self.seen
                .lock()
                .unwrap()
                .push(format!("{}:{}", self.id, d.text));
        }
    }

    struct Silent;
    impl Extension for Silent {
        fn id(&self) -> &'static str {
            "silent"
        }
    }

    const HELLO: FinishedDictation<'static> = FinishedDictation {
        text: "hello",
        language: Some("en"),
        inserted: true,
    };

    #[test]
    fn the_free_build_registers_nothing() {
        let mut registry = Registry::default();
        assert!(registry.is_empty());
        assert_eq!(registry.len(), 0);
        registry.dictation_finished(&HELLO); // no extensions: a no-op, no panic
        assert!(registry.ids().is_empty());
    }

    #[test]
    fn extensions_hear_finished_dictations_in_registration_order() {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let mut registry = Registry::new();
        registry
            .register(Box::new(Recorder {
                id: "a",
                seen: seen.clone(),
            }))
            .unwrap();
        registry.register(Box::new(Silent)).unwrap();
        registry
            .register(Box::new(Recorder {
                id: "b",
                seen: seen.clone(),
            }))
            .unwrap();
        registry.dictation_finished(&HELLO);
        assert_eq!(*seen.lock().unwrap(), vec!["a:hello", "b:hello"]);
        assert_eq!(registry.ids(), vec!["a", "silent", "b"]);
    }

    #[test]
    fn duplicate_ids_are_refused() {
        let mut registry = Registry::new();
        registry.register(Box::new(Silent)).unwrap();
        assert_eq!(
            registry.register(Box::new(Silent)),
            Err(RegistryError::DuplicateId("silent"))
        );
        assert_eq!(registry.len(), 1);
    }
}
