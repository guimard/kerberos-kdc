# Spec — Plugin LemonLDAP::NG « Provisioning Kerberos à la volée »

> Document de cadrage destiné au développeur (ou à l'agent) en charge du plugin
> LemonLDAP::NG. Il décrit **ce que le plugin doit faire**, pas comment il sera
> intégré au reste de la stack. Le KDC et l'annuaire Kerberos dédié sont fournis
> par ailleurs (projet `pure-kdc`).

## 1. Contexte

On déploie un KDC Kerberos (MIT) dont la base est un **OpenLDAP dédié** ne
contenant que des principals Kerberos autonomes (`krbPrincipal` sous un
`krbContainer`). La **source de vérité des identités** est l'annuaire LDAP
général de l'entreprise, que l'on ne modifie pas.

Kerberos ne peut **pas** déléguer l'authentification à un annuaire au moment du
`kinit` : le KDC a besoin de la **clé dérivée du mot de passe** déjà présente
dans sa base. On ne peut donc fabriquer cette clé qu'au moment où **quelqu'un
voit le mot de passe en clair**.

LemonLDAP::NG **est** ce moment : le SSO authentifie déjà l'utilisateur contre
l'annuaire général (la validation est donc acquise), et il tient le mot de
passe en clair pendant ce processus. Le plugin transforme cette authentification
réussie en **provisioning/synchronisation** du principal Kerberos.

## 2. Principe

```
  user ─(login + mot de passe clair)─► LemonLDAP::NG
                                          │  (auth LDAP général = validation, déjà en place)
                                          │
                                          └─[plugin, hook endAuth]─► kadmind
                                                  addprinc / cpw idempotent
                                                          │
                                                          ▼
                                              OpenLDAP Kerberos dédié
```

À chaque **login réel**, le plugin pose (ou repose) la clé Kerberos de
l'utilisateur égale à son mot de passe courant. Ensuite l'utilisateur peut
obtenir des tickets (`kinit`/SSO Kerberos) contre le KDC.

## 3. Déclenchement

- **Hook : `endAuth`** (fin du processus d'authentification, après succès).
  Déclaré dans le plugin via `use constant endAuth => '<méthode>';`.
- À **vérifier sur la version cible** de LLNG : que `$req->data->{password}`
  est **encore peuplé** à ce stade. Si ce n'est plus le cas, se brancher plus
  tôt (p. ex. `afterData`), tout en conservant la garantie « auth réussie ».
- Le hook ne doit agir **que** lorsqu'un mot de passe est réellement présent
  (voir §9). Sur un accès SSO par cookie/session déjà ouverte, ou sur une
  authentification fédérée sans mot de passe (SAML/OIDC entrant, SPNEGO), il
  n'y a pas de clair → **no-op silencieux**.

## 4. Entrées disponibles à l'exécution du hook

| Donnée | Source (à confirmer selon version) |
|---|---|
| Identifiant utilisateur | `$req->{user}` ou un attribut de session (`$req->{sessionInfo}{uid}`) |
| Mot de passe en clair | `$req->data->{password}` |
| Attributs de session | `$req->{sessionInfo}{...}` (pour le mapping du principal) |
| Configuration du plugin | `$self->conf->{...}` (voir §8) |

## 5. Comportement attendu (algorithme)

```
1. Si le provisioning est désactivé (conf) → PE_OK.
2. Déduire le nom de principal depuis l'identité (voir §6). Si impossible → log debug + PE_OK.
3. Récupérer le mot de passe en clair. Si absent/vide → PE_OK (no-op).
4. Se connecter à kadmind avec le principal de service (keytab).
5. Idempotent :
     - si le principal n'existe pas  → le créer avec ce mot de passe (addprinc) ;
     - s'il existe                   → repositionner sa clé sur ce mot de passe (cpw).
   (Faire le cpw à CHAQUE login, pas seulement à la création, pour résorber la
    dérive si le mot de passe a changé côté annuaire général.)
6. En cas d'erreur → logguer en error, NE PAS faire échouer l'auth → PE_OK.
7. Ne jamais journaliser ni stocker le mot de passe.
```

Le `cpw` systématique est volontaire : c'est le mécanisme de resynchronisation.

## 6. Mapping identité → principal Kerberos

- Principal = `format(attribut, realm)`, **configurable**.
- Par défaut : `<uid>@<REALM>` où `<uid>` est l'attribut de session configuré
  (défaut : l'identifiant de login).
- Le realm vient de la configuration du plugin, pas de l'identité.
- Refuser/ignorer proprement un identifiant vide ou contenant des caractères
  invalides pour un principal.

## 7. Accès à kadmind

- Le plugin s'authentifie auprès de `kadmind` avec un **principal de service
  dédié** (p. ex. `lemonldap/admin@REALM`) via un **keytab** lisible seulement
  par le process LLNG.
- Côté KDC, `kadm5.acl` doit accorder à ce principal **uniquement** les droits
  nécessaires : `add`, `changepw`, `modify` (pas de `delete`, pas `*`).
- **Deux implémentations possibles**, par ordre de préférence :
  1. **`Authen::Krb5::Admin`** (bindings `libkadm5`) → `create_principal` /
     `chpass_principal` **en mémoire**. Pas de shell, pas de fuite.
  2. À défaut, shell vers `kadmin -k -t <keytab> -p <principal>` en injectant le
     mot de passe par **stdin** (prompt interactif de `cpw`/`addprinc`).
- **Interdit** : passer le mot de passe via `-pw` en argument de ligne de
  commande (visible dans `/proc/<pid>/cmdline`).

## 8. Paramètres de configuration du plugin

À exposer dans la configuration LLNG (noms indicatifs) :

| Paramètre | Rôle | Défaut |
|---|---|---|
| `krbProvisioningActivation` | Active/désactive le plugin | `0` |
| `krbRealm` | Realm Kerberos | (obligatoire) |
| `krbAdminServer` | `host[:port]` de kadmind | (obligatoire) |
| `krbServicePrincipal` | Principal de service du plugin | (obligatoire) |
| `krbKeytab` | Chemin du keytab | (obligatoire) |
| `krbPrincipalAttribute` | Attribut de session servant de nom de principal | login |
| `krbPrincipalFormat` | Gabarit `principal@realm` | `%s@%s` |
| `krbDefaultPolicy` | Politique Kerberos à appliquer (optionnel) | (vide) |
| `krbConnectTimeout` | Timeout kadmind (s) | `3` |

## 9. Contraintes impératives

1. **Non bloquant** : aucune erreur de provisioning ne doit empêcher
   l'authentification SSO. Toujours retourner `PE_OK`.
2. **Pas de persistance du mot de passe** : il n'est utilisé qu'en mémoire, le
   temps de l'appel kadmin. Ne pas activer `storePassword` pour ça.
3. **Pas de mot de passe en argv** (cf. §7).
4. **No-op** propre quand il n'y a pas de mot de passe (SSO cookie, fédération).
5. **Timeout court** sur kadmind : un kadmind indisponible ne doit pas faire
   traîner (ni a fortiori bloquer) le login.

## 10. Hors périmètre

- **Déprovisioning** : la suppression/désactivation d'un compte côté annuaire
  général n'est PAS vue par LLNG (pas d'événement). Elle est gérée par un **job
  de réconciliation** séparé, hors de ce plugin.
- Création des comptes de service, du `krbContainer`, du realm : côté
  `pure-kdc`.

## 11. Observabilité

- Log `info` à la création d'un principal, `debug` à un cpw de routine,
  `error` en cas d'échec kadmin (avec le nom du principal, **jamais** le mot de
  passe).
- Idéalement un compteur (provisionings réussis / échoués) pour supervision.

## 12. Critères d'acceptation

1. **Premier login** d'un utilisateur connu de l'annuaire général : le principal
   `<uid>@REALM` est créé ; un `kinit <uid>` avec ce mot de passe **réussit**.
2. **Login répété** : pas d'erreur, `kinit` continue de fonctionner (cpw idempotent).
3. **Changement de mot de passe** côté annuaire général, puis nouveau login SSO :
   le `kinit` réussit avec le **nouveau** mot de passe (resync).
4. **kadmind arrêté** pendant un login : l'authentification SSO **réussit quand
   même** (provisioning loggé en échec, non bloquant).
5. **Accès SSO par cookie** (sans ressaisie) : aucun appel kadmin (no-op).
6. Le mot de passe n'apparaît **dans aucun log** ni dans `/proc`.

## 13. Squelette indicatif (à recaler sur la version LLNG cible)

```perl
package Lemonldap::NG::Portal::Plugins::KrbProvisioning;
use Mouse;
extends 'Lemonldap::NG::Portal::Main::Plugin';
use Lemonldap::NG::Portal::Main::Constants qw(PE_OK);

# Hook : exécuté en fin d'authentification réussie
use constant endAuth => 'provision';

sub init {
    my ($self) = @_;
    return 0 unless $self->conf->{krbProvisioningActivation};
    # valider la présence des paramètres obligatoires ici
    return 1;
}

sub provision {
    my ( $self, $req ) = @_;

    my $attr  = $self->conf->{krbPrincipalAttribute} || '_user';
    my $login = $req->{sessionInfo}{$attr} // $req->{user};
    my $pwd   = $req->data->{password};

    return PE_OK unless $login && defined $pwd && length $pwd;   # no-op (SSO/fédéré)

    my $princ = sprintf(
        $self->conf->{krbPrincipalFormat} || '%s@%s',
        $login, $self->conf->{krbRealm}
    );

    eval { $self->_setKerberosPassword( $princ, $pwd ); 1 }
      or $self->logger->error("Kerberos provisioning failed for $princ: $@");

    return PE_OK;   # JAMAIS bloquant
}

# Authen::Krb5::Admin de préférence ; sinon kadmin via stdin (pas -pw)
sub _setKerberosPassword { ... }

1;
```

Activation : ajouter le package à `customPlugins` dans la configuration LLNG.

## 14. Références

- LemonLDAP::NG — « Write your own plugin » (doc *devplugin* de la version cible)
- MIT Kerberos — `kadmin`, `kadm5.acl`
- CPAN — `Authen::Krb5::Admin`
- Projet `pure-kdc` — KDC + annuaire Kerberos dédié (cette stack)
