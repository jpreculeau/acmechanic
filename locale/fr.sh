# shellcheck shell=bash disable=SC2034
# locale/fr.sh - Catalogue de REFERENCE (francais). Toute nouvelle cle
# s'ajoute ici d'abord, puis dans chaque autre catalogue.
MSG=(
	# --- Affichage fixe : en-tete ---
	[sous_titre]="le grand show de la maintenance"
	[coulisses]="…patiente dans les coulisses"
	# --- Statuts (pastille de chaque cadre) ---
	[statut_travail]="au travail"
	[statut_maj]="mis à jour"
	[statut_ok]="ok"
	[statut_inchange]="inchangé"
	[statut_ignore]="ignoré"
	[statut_attente]="en attente"
	[statut_timeout]="trop long"
	[statut_echec]="échec"
	# --- Onomatopees (bas de cadre) ; bruit_travail : liste separee par | ---
	[bruit_travail]="Zip !|Zoom !|Vroum !|Bip bip !|Hop hop !|Boing !|Wiizz !|Tagada !"
	[bruit_maj]="Tadaa !"
	[bruit_ok]="Nickel !"
	[bruit_ignore]="Pouf !"
	[bruit_attente]="Au suivant…"
	[bruit_timeout]="Zzzz…"
	[bruit_echec]="Patatras !"
	# --- Bilan ---
	[titre_services]="Services"
	[bilan_maj]="%d mis à jour"
	[bilan_inchange_1]="%d inchangé"
	[bilan_inchange_n]="%d inchangés"
	[bilan_ok_1]="%d terminé"
	[bilan_ok_n]="%d terminés"
	[bilan_ignore_1]="%d ignoré"
	[bilan_ignore_n]="%d ignorés"
	[bilan_echec]="%d en échec"
	[bilan_etapes]="Étapes : %d réussie(s) · %d ignorée(s) · %d en échec"
	[journal]="Journal complet : %s"
	[sorties]="Sorties détaillées : %s"
	[titre_attention]="Points d'attention"
	[titre_erreurs]="Erreurs"
	[attention_commande]="à lancer : %s"
	[titre_versions]="Versions"
	# --- Fin ---
	[fin_ok]="Rideau ! Tout est en ordre."
	[fin_echec]="Patatras ! %d étape(s) en échec."
	[restauration]="restauration : %s"
	[disque]="%s libres (%s utilisés)"
	[sauvegardes]="%s de sauvegardes"
	# --- Points d'attention d'Acmechanic lui-meme ---
	[att_redemarrage]="Redémarrage nécessaire pour terminer les mises à jour (%s)"
	[att_auto_maj]="Nouvelle version d'Acmechanic disponible (%d commit(s)), non appliquée : %s"
	[raison_modifs]="modifications locales"
	[raison_divergent]="historique local divergent"
	[raison_signaler]="ACMECHANIC_AUTO_MAJ=signaler"
)
